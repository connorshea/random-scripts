// Classify every item in a QuickStatements batch: human (Q5), musical group (Q215380 or a subclass), or neither.
// Usage: node types.mjs [batch.qs.tsv]   (defaults to mb-artist-ids.qs.tsv)
// Writes not-human-or-group.tsv with each other item and its instance of values.
import { readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { UA } from "./user-agent.mjs";

const batchPath = process.argv[2] ?? "mb-artist-ids.qs.tsv";
const qids = readFileSync(batchPath, "utf8").trim().split("\n").map((l) => l.split("\t")[0]);
const P = "PREFIX wd: <http://www.wikidata.org/entity/>\nPREFIX wdt: <http://www.wikidata.org/prop/direct/>\nPREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>\n";
const types = new Map(qids.map((q) => [q, { human: false, group: false, other: [] }]));
const labels = new Map();
for (let i = 0; i < qids.length; i += 5000) {
  const values = qids.slice(i, i + 5000).map((q) => `wd:${q}`).join(" ");
  const query = `${P}SELECT ?item ?type ?typeLabel ?isGroup WHERE {
  VALUES ?item { ${values} }
  ?item wdt:P31 ?type .
  OPTIONAL { ?type rdfs:label ?typeLabel . FILTER(LANG(?typeLabel) = "en") }
  OPTIONAL { ?type wdt:P279* wd:Q215380 . BIND(true AS ?isGroup) }
}`;
  let res;
  for (let attempt = 0; ; attempt++) {
    await sleep(5000);
    res = await fetch("https://qlever.dev/api/wikidata", { method: "POST", headers: { "User-Agent": UA, Accept: "application/sparql-results+json", "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ query }) });
    if ((res.status !== 429 && res.status < 500) || attempt >= 5) break;
    const wait = Number(res.headers.get("retry-after")) || 60 * 2 ** attempt;
    console.error(`${res.status}, waiting ${wait}s`);
    await sleep(wait * 1000);
  }
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  for (const b of (await res.json()).results.bindings) {
    const q = b.item.value.split("/").pop(), t = b.type.value.split("/").pop();
    const e = types.get(q);
    if (t === "Q5") e.human = true;
    else if (b.isGroup) e.group = true;
    else e.other.push(t);
    labels.set(t, b.typeLabel?.value ?? t);
  }
}
const summary = { human: 0, group: 0, both: 0, neither: 0, noP31: 0 };
const neitherTypes = {};
const rows = [];
for (const [q, e] of types) {
  if (e.human && e.group) summary.both++;
  else if (e.human) summary.human++;
  else if (e.group) summary.group++;
  else if (e.other.length === 0) { summary.noP31++; rows.push(`${q}\t(no instance of)`); }
  else {
    summary.neither++;
    rows.push(`${q}\t${e.other.map((t) => `${t} ${labels.get(t)}`).join("; ")}`);
    for (const t of e.other) neitherTypes[`${t} ${labels.get(t)}`] = (neitherTypes[`${t} ${labels.get(t)}`] ?? 0) + 1;
  }
}
writeFileSync("not-human-or-group.tsv", rows.join("\n") + "\n");
console.log(summary);
console.log(Object.entries(neitherTypes).sort((a, b) => b[1] - a[1]).slice(0, 30));
