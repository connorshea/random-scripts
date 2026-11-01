// Build the Discogs artist ID (P1953) batch from reverse-name-check.tsv.
//
// Keeps rows whose Discogs name, name variation or real name matches the MusicBrainz name, then checks
// live Wikidata through QLever (one request at a time, 5s apart):
// - the item is a human, a musical group (or subclass), musical ensemble, orchestra, duo or musical trio
// - the item still has no Discogs artist ID, and the Discogs ID isn't on any item yet
// Reference: matched by identifier from (P11797): MusicBrainz (Q14005), MusicBrainz artist ID (P434), retrieved (P813)
//
// Usage: node reverse-build.mjs   (run from the folder holding reverse-name-check.tsv)

import { readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { UA } from "./user-agent.mjs";

const PREFIXES = `PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX p: <http://www.wikidata.org/prop/>
PREFIX ps: <http://www.wikidata.org/prop/statement/>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
`;
let last = 0;
async function qlever(query, attempt = 0) {
  const wait = last + 5000 - Date.now();
  if (wait > 0) await sleep(wait);
  last = Date.now();
  const res = await fetch("https://qlever.dev/api/wikidata", {
    method: "POST",
    headers: { "User-Agent": UA, Accept: "application/sparql-results+json", "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ query: PREFIXES + query }),
  });
  if (res.status === 429 || res.status >= 500) {
    if (attempt >= 5) throw new Error(`${res.status}`);
    const s = Number(res.headers.get("retry-after")) || 60 * 2 ** attempt;
    console.error(`${res.status}, waiting ${s}s`);
    await sleep(s * 1000);
    return qlever(query, attempt + 1);
  }
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  return (await res.json()).results.bindings;
}
const qidOf = (iri) => iri.split("/").pop();

const rows = readFileSync("reverse-name-check.tsv", "utf8")
  .trim()
  .split("\n")
  .slice(1)
  .map((l) => l.split("\t"))
  .filter(([result]) => result === "nameMatch" || result === "variationOrRealnameMatch")
  .map(([result, qid, mbid, mbName, discogs, discogsName]) => ({ result, qid, mbid, mbName, discogs, discogsName }));

const KEEP_EXTRA = new Set(["Q2088357", "Q42998", "Q10648343", "Q281643"]); // musical ensemble, orchestra, duo, musical trio
const okType = new Set();
const types = new Map();
const nowHasDiscogs = new Set();
const discogsInUse = new Set();
const BATCH = 5000;
for (let i = 0; i < rows.length; i += BATCH) {
  const chunk = rows.slice(i, i + BATCH);
  const items = chunk.map((r) => `wd:${r.qid}`).join(" ");
  for (const b of await qlever(`SELECT ?item ?type ?isGroup WHERE {
  VALUES ?item { ${items} }
  ?item wdt:P31 ?type .
  OPTIONAL { ?type wdt:P279* wd:Q215380 . BIND(true AS ?isGroup) }
}`)) {
    const q = qidOf(b.item.value), t = qidOf(b.type.value);
    (types.get(q) ?? types.set(q, []).get(q)).push(t);
    if (t === "Q5" || b.isGroup || KEEP_EXTRA.has(t)) okType.add(q);
  }
  for (const b of await qlever(`SELECT DISTINCT ?item WHERE { VALUES ?item { ${items} } ?item p:P1953 [] }`)) nowHasDiscogs.add(qidOf(b.item.value));
  const ids = chunk.map((r) => `"${r.discogs}"`).join(" ");
  for (const b of await qlever(`SELECT DISTINCT ?d WHERE { VALUES ?d { ${ids} } ?item p:P1953/ps:P1953 ?d }`)) discogsInUse.add(b.d.value);
  console.error(`checked ${Math.min(i + BATCH, rows.length)}/${rows.length}`);
}

const today = `+${new Date().toISOString().slice(0, 10)}T00:00:00Z/11`;
const accepted = [];
const dropped = [];
for (const r of rows) {
  let reason = null;
  if (!okType.has(r.qid)) reason = `type: ${(types.get(r.qid) ?? ["(no instance of)"]).join(",")}`;
  else if (nowHasDiscogs.has(r.qid)) reason = "item has a Discogs ID now";
  else if (discogsInUse.has(r.discogs)) reason = "Discogs ID on an item now";
  if (reason) dropped.push({ ...r, reason });
  else accepted.push(r);
}

const qs = accepted.map((r) => `${r.qid}\tP1953\t"${r.discogs}"\tS11797\tQ14005\tS434\t"${r.mbid}"\tS813\t${today}`);
writeFileSync("discogs-ids.qs.tsv", qs.join("\n") + "\n");
writeFileSync("discogs-ids.first20.qs.tsv", qs.slice(0, 20).join("\n") + "\n");
writeFileSync("discogs-ids.rest.qs.tsv", qs.slice(20).join("\n") + "\n");
writeFileSync("discogs-ids.dropped.tsv", ["reason\tqid\tmbName\tdiscogsName\tdiscogs\tmbid", ...dropped.map((r) => [r.reason, r.qid, r.mbName, r.discogsName, r.discogs, r.mbid].join("\t"))].join("\n") + "\n");

const reasons = {};
for (const d of dropped) { const k = d.reason.startsWith("type:") ? "not human/group/ensemble/orchestra/duo/trio" : d.reason; reasons[k] = (reasons[k] ?? 0) + 1; }
console.log({ nameOrVariationMatches: rows.length, accepted: accepted.length, nameMatch: accepted.filter((r) => r.result === "nameMatch").length, variationMatch: accepted.filter((r) => r.result !== "nameMatch").length, dropped: reasons });
