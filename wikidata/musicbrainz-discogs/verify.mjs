// Cross-check the MusicBrainz ID batch against the raw inputs, then check live Wikidata via QLever.
// Run from the folder holding candidates.json, rejected.tsv, wd-discogs-no-mb.tsv and the
// mb-artist-ids{,.first20,.rest}.qs.tsv files.
import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { UA } from "./user-agent.mjs";

const fail = [];
const candidates = JSON.parse(readFileSync("candidates.json", "utf8"));
const byQid = new Map(candidates.map((c) => [c.qid, c]));
const rejectedQids = new Set(readFileSync("rejected.tsv", "utf8").split("\n").slice(1).filter(Boolean).map((l) => l.split("\t")[1]));
const first20 = readFileSync("mb-artist-ids.first20.qs.tsv", "utf8").trim().split("\n");
const rest = readFileSync("mb-artist-ids.rest.qs.tsv", "utf8").trim().split("\n");
const all = readFileSync("mb-artist-ids.qs.tsv", "utf8").trim().split("\n");

// Wikidata's Discogs IDs from the original query
const wdDiscogs = new Map();
for (const l of readFileSync("wd-discogs-no-mb.tsv", "utf8").split("\n").slice(1)) {
  const m = l.match(/(Q\d+)>\t"(.*)"$/);
  if (m) (wdDiscogs.get(m[1]) ?? wdDiscogs.set(m[1], []).get(m[1])).push(m[2]);
}

if (first20.concat(rest).join("\n") !== all.join("\n")) fail.push("first20 + rest != full batch");
const line = /^(Q\d+)\tP434\t"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"\tS11797\tQ504063\tS1953\t"(\d+)"\tS813\t\+\d{4}-\d{2}-\d{2}T00:00:00Z\/11$/;
const seenQ = new Set(), seenM = new Set();
for (const l of all) {
  const m = l.match(line);
  if (!m) { fail.push(`bad format: ${l}`); continue; }
  const [, qid, mbid, discogs] = m;
  const c = byQid.get(qid);
  if (!c) fail.push(`${qid} not a candidate`);
  else if (c.mbid !== mbid || c.discogs !== discogs) fail.push(`${qid} mbid/discogs differ from candidates.json`);
  if (rejectedQids.has(qid)) fail.push(`${qid} is in rejected.tsv`);
  const d = wdDiscogs.get(qid) ?? [];
  if (d.length !== 1 || d[0] !== discogs) fail.push(`${qid} Wikidata Discogs IDs ${d} != ${discogs}`);
  if (seenQ.has(qid)) fail.push(`dup qid ${qid}`);
  if (seenM.has(mbid)) fail.push(`dup mbid ${mbid}`);
  seenQ.add(qid); seenM.add(mbid);
}
console.log({ lines: all.length, first20: first20.length, rest: rest.length, offlineFailures: fail.length });
fail.slice(0, 10).forEach((f) => console.log(f));

// Live check on the commands still to run: any MB ID on any item now, and current Discogs ID still the same
const P = "PREFIX wd: <http://www.wikidata.org/entity/>\nPREFIX wdt: <http://www.wikidata.org/prop/direct/>\nPREFIX p: <http://www.wikidata.org/prop/>\nPREFIX ps: <http://www.wikidata.org/prop/statement/>\n";
async function q(query, attempt = 0) {
  await sleep(5000);
  const res = await fetch("https://qlever.dev/api/wikidata", { method: "POST", headers: { "User-Agent": UA, Accept: "application/sparql-results+json", "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ query: P + query }) });
  if ((res.status === 429 || res.status >= 500) && attempt < 5) {
    const wait = Number(res.headers.get("retry-after")) || 60 * 2 ** attempt;
    console.error(`${res.status}, waiting ${wait}s`);
    await sleep(wait * 1000);
    return q(query, attempt + 1);
  }
  if (!res.ok) throw new Error(`${res.status}`);
  return (await res.json()).results.bindings;
}
const restRows = rest.map((l) => l.match(line)).map(([, qid, mbid, discogs]) => ({ qid, mbid, discogs }));
const live = { itemNowHasMb: [], mbidNowUsed: [], discogsChanged: [] };
for (let i = 0; i < restRows.length; i += 5000) {
  const chunk = restRows.slice(i, i + 5000);
  const items = chunk.map((r) => `wd:${r.qid}`).join(" ");
  for (const b of await q(`SELECT ?item ?mb WHERE { VALUES ?item { ${items} } ?item p:P434/ps:P434 ?mb }`)) live.itemNowHasMb.push(`${b.item.value.split("/").pop()} ${b.mb.value}`);
  const mbids = chunk.map((r) => `"${r.mbid}"`).join(" ");
  for (const b of await q(`SELECT ?item ?mb WHERE { VALUES ?mb { ${mbids} } ?item p:P434/ps:P434 ?mb }`)) live.mbidNowUsed.push(`${b.item.value.split("/").pop()} ${b.mb.value}`);
  const want = new Map(chunk.map((r) => [r.qid, r.discogs]));
  const got = new Map();
  for (const b of await q(`SELECT ?item ?d WHERE { VALUES ?item { ${items} } ?item wdt:P1953 ?d }`)) {
    const qid = b.item.value.split("/").pop();
    (got.get(qid) ?? got.set(qid, []).get(qid)).push(b.d.value);
  }
  for (const [qid, d] of want) { const g = got.get(qid) ?? []; if (g.length !== 1 || g[0] !== d) live.discogsChanged.push(`${qid} ${d} -> ${g.join(",") || "none"}`); }
}
console.log(Object.fromEntries(Object.entries(live).map(([k, v]) => [k, v.length])));
for (const [k, v] of Object.entries(live)) v.slice(0, 10).forEach((x) => console.log(k, x));
