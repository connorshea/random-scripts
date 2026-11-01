// Measure how many dropped label matches each candidate looser rule would recover.
// Usage: node analyze-misses.mjs ~/Downloads/discogs_20261001_artists.xml.gz
//   (run from the folder holding discogs-ids.label-dropped.tsv and reverse-name-check.tsv)
// Writes analyze-misses.tsv. Reads the dump read-only.

import { createReadStream, readFileSync, writeFileSync } from "node:fs";
import { createGunzip } from "node:zlib";
import { setTimeout as sleep } from "node:timers/promises";
import { normalize, stripDiscogsSuffix } from "./normalize.mjs";
import { UA } from "./user-agent.mjs";

const rows = readFileSync("discogs-ids.label-dropped.tsv", "utf8").trim().split("\n").slice(1).map((l) => {
  const [result, qid, wdLabel, , discogsName, discogs] = l.split("\t");
  return { result, qid, wdLabel, discogsName, discogs };
});
const mbName = new Map(readFileSync("reverse-name-check.tsv", "utf8").trim().split("\n").slice(1).map((l) => l.split("\t")).map((f) => [f[1], f[3]]));

// Discogs names, variations and real names
const decode = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n)).replace(/&amp;/g, "&");
const wanted = new Set(rows.map((r) => r.discogs));
const dnames = new Map();
let buf = "";
const stream = createReadStream(process.argv[2], { flags: "r" }).pipe(createGunzip());
stream.setEncoding("utf8");
const take = (line) => {
  const id = line.match(/^<artist><id>(\d+)<\/id>/)?.[1];
  if (!id || !wanted.has(id)) return;
  const names = [line.match(/<name>([^<]*)<\/name>/)?.[1], line.match(/<realname>([^<]*)<\/realname>/)?.[1], ...[...(line.match(/<namevariations>(.*?)<\/namevariations>/)?.[1] ?? "").matchAll(/<name>([^<]*)<\/name>/g)].map((m) => m[1])];
  dnames.set(id, names.filter(Boolean).map((n) => stripDiscogsSuffix(decode(n))));
};
for await (const chunk of stream) {
  buf += chunk;
  let i;
  while ((i = buf.indexOf("\n")) !== -1) { take(buf.slice(0, i)); buf = buf.slice(i + 1); }
}

// Wikidata labels in every language, and aliases
const wdNames = new Map();
for (let i = 0; i < rows.length; i += 2500) {
  await sleep(5000);
  const values = rows.slice(i, i + 2500).map((r) => `wd:${r.qid}`).join(" ");
  const query = `PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
SELECT ?item ?n WHERE { VALUES ?item { ${values} } { ?item rdfs:label ?n } UNION { ?item skos:altLabel ?n } }`;
  let res;
  for (let a = 0; ; a++) {
    res = await fetch("https://qlever.dev/api/wikidata", { method: "POST", headers: { "User-Agent": UA, Accept: "application/sparql-results+json", "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ query }) });
    if ((res.status !== 429 && res.status < 500) || a >= 5) break;
    const w = Number(res.headers.get("retry-after")) || 60 * 2 ** a;
    console.error(`${res.status}, waiting ${w}s`);
    await sleep(w * 1000);
  }
  if (!res.ok) throw new Error(`${res.status}`);
  for (const b of (await res.json()).results.bindings) {
    const q = b.item.value.split("/").pop();
    (wdNames.get(q) ?? wdNames.set(q, new Set()).get(q)).add(b.n.value);
  }
}

// Candidate looser normalizations, applied to both sides
const noThe = (s) => normalize(s).replace(/^the /, "");
const squash = (s) => noThe(s).replace(/ /g, "");
const tokens = (s) => noThe(s).split(" ").sort().join(" ");

const rules = {
  "1 drop a leading The": (a, b) => noThe(a) === noThe(b),
  "2 ignore spaces too (PS22 / PS 22)": (a, b) => squash(a) === squash(b),
  "3 same words in any order": (a, b) => tokens(a) === tokens(b),
};
const counts = {};
const recovered = new Set();
const out = [];
for (const r of rows) {
  const ds = dnames.get(r.discogs) ?? [];
  const label = r.wdLabel;
  const all = [...(wdNames.get(r.qid) ?? [])];
  const hit = [];
  if (label) for (const [name, f] of Object.entries(rules)) if (ds.some((d) => f(label, d))) hit.push(name);
  if (all.some((w) => ds.some((d) => normalize(w) === normalize(d)))) hit.push("4 any-language label or alias matches");
  if (label && normalize(label) === normalize(mbName.get(r.qid) ?? "")) hit.push("5 label matches the MusicBrainz name");
  for (const h of hit) counts[`${r.result}: ${h}`] = (counts[`${r.result}: ${h}`] ?? 0) + 1;
  if (hit.length) recovered.add(r.qid);
  out.push([r.result, r.qid, label, ds[0] ?? "", hit.map((h) => h[0]).join(",")].join("\t"));
}
writeFileSync("analyze-misses.tsv", ["result\tqid\twdLabel\tdiscogsName\trules", ...out].join("\n") + "\n");
console.log(Object.fromEntries(Object.entries(counts).sort()));
console.log({ dropped: rows.length, recoveredByAnyRule: recovered.size });
