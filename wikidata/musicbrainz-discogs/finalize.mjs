// Take the candidates from match.mjs, compare names against Wikidata labels, check the
// MusicBrainz IDs aren't already used on another item, and write a QuickStatements batch.
// Both checks query QLever's Wikidata endpoint, which has live updates and no per-minute limit.
//
// Usage: node finalize.mjs candidates.json <out-dir>
// Writes <out-dir>/mb-artist-ids.qs.tsv, <out-dir>/rejected.tsv and <out-dir>/accepted.tsv

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { normalize } from "./normalize.mjs";
import { UA } from "./user-agent.mjs";

const [candidatesPath, outDir] = process.argv.slice(2);
const candidates = JSON.parse(readFileSync(candidatesPath, "utf8"));

async function fetchJson(url, init = {}, attempt = 0) {
  const res = await fetch(url, { ...init, headers: { "User-Agent": UA, Accept: "application/json", ...init.headers } });
  if (res.status === 429 || res.status >= 500) {
    if (attempt >= 5) throw new Error(`${res.status} from ${url}`);
    const wait = Number(res.headers.get("retry-after")) || 60 * 2 ** attempt;
    console.error(`${res.status}, waiting ${wait}s`);
    await sleep(wait * 1000);
    return fetchJson(url, init, attempt + 1);
  }
  return res.json();
}

const QLEVER = "https://qlever.dev/api/wikidata";
const PREFIXES = `PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX p: <http://www.wikidata.org/prop/>
PREFIX ps: <http://www.wikidata.org/prop/statement/>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
`;
// One request at a time, with a pause between them, to go easy on the public endpoint
const PAUSE_MS = 5000;
let lastRequest = 0;
const qlever = async (query) => {
  const wait = lastRequest + PAUSE_MS - Date.now();
  if (wait > 0) await sleep(wait);
  lastRequest = Date.now();
  return fetchJson(QLEVER, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/sparql-results+json" },
    body: new URLSearchParams({ query: PREFIXES + query }),
  });
};
const BATCH = 5000;

// 1. Labels. VALUES always yields a row, so a redirected or deleted item comes back with no labels
// and ends up under "no en or mul label".
const labels = new Map(); // qid -> { label, lang }
const qids = [...new Set(candidates.map((c) => c.qid))];
for (let i = 0; i < qids.length; i += BATCH) {
  const values = qids.slice(i, i + BATCH).map((q) => `wd:${q}`).join(" ");
  const body = await qlever(`SELECT ?item ?en ?mul WHERE {
  VALUES ?item { ${values} }
  OPTIONAL { ?item rdfs:label ?en . FILTER(LANG(?en) = "en") }
  OPTIONAL { ?item rdfs:label ?mul . FILTER(LANG(?mul) = "mul") }
}`);
  for (const b of body.results.bindings) {
    const qid = b.item.value.split("/").pop();
    const en = b.en?.value;
    const mul = b.mul?.value;
    labels.set(qid, en ? { label: en, lang: "en" } : mul ? { label: mul, lang: "mul" } : { label: "", lang: "" });
  }
  console.error(`labels ${Math.min(i + BATCH, qids.length)}/${qids.length}`);
}

// 2. MusicBrainz IDs already on some Wikidata item (any rank)
const mbidInUse = new Map(); // mbid -> qids
const mbids = [...new Set(candidates.map((c) => c.mbid))];
for (let i = 0; i < mbids.length; i += BATCH) {
  const values = mbids.slice(i, i + BATCH).map((m) => `"${m}"`).join(" ");
  const body = await qlever(`SELECT ?item ?mbid WHERE { VALUES ?mbid { ${values} } ?item p:P434/ps:P434 ?mbid . }`);
  for (const b of body.results.bindings) {
    const qid = b.item.value.split("/").pop();
    if (!mbidInUse.has(b.mbid.value)) mbidInUse.set(b.mbid.value, []);
    mbidInUse.get(b.mbid.value).push(qid);
  }
  console.error(`mbid check ${Math.min(i + BATCH, mbids.length)}/${mbids.length}`);
}

// 3. Compare
const accepted = [];
const rejected = [];
for (const c of candidates) {
  const label = labels.get(c.qid) ?? null;
  let reason = null;
  if (label === null) reason = "item missing or redirected";
  else if (!label.label) reason = "no en or mul label";
  else if (normalize(label.label) !== normalize(c.mbName)) reason = "name mismatch";
  else if (mbidInUse.has(c.mbid)) reason = `MB ID already on ${mbidInUse.get(c.mbid).join(",")}`;
  const row = { ...c, wdLabel: label?.label ?? "", wdLabelLang: label?.lang ?? "" };
  if (reason) rejected.push({ ...row, reason });
  else accepted.push(row);
}

const tsv = (rows, cols) => [cols.join("\t"), ...rows.map((r) => cols.map((k) => String(r[k] ?? "").replace(/\s/g, " ")).join("\t"))].join("\n") + "\n";
// Reference in the style of the other ID importers in this repo:
// matched by identifier from (P11797): Discogs (Q504063), Discogs artist ID (P1953), retrieved (P813)
const today = `+${new Date().toISOString().slice(0, 10)}T00:00:00Z/11`;
writeFileSync(
  join(outDir, "mb-artist-ids.qs.tsv"),
  accepted.map((r) => `${r.qid}\tP434\t"${r.mbid}"\tS11797\tQ504063\tS1953\t"${r.discogs}"\tS813\t${today}`).join("\n") + "\n",
);
writeFileSync(join(outDir, "accepted.tsv"), tsv(accepted, ["qid", "wdLabel", "wdLabelLang", "mbName", "mbDisambiguation", "mbid", "discogs", "mbLinksThisItem"]));
writeFileSync(join(outDir, "rejected.tsv"), tsv(rejected, ["reason", "qid", "wdLabel", "wdLabelLang", "mbName", "mbDisambiguation", "mbid", "discogs"]));

const reasons = {};
for (const r of rejected) {
  const key = r.reason.startsWith("MB ID already on") ? "MB ID already on another item" : r.reason;
  reasons[key] = (reasons[key] ?? 0) + 1;
}
console.error(JSON.stringify({ candidates: candidates.length, accepted: accepted.length, rejected: reasons }, null, 2));
