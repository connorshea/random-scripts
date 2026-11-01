// Filter discogs-ids.qs.tsv to items whose Wikidata en label (or mul, when there's no en label) matches
// the Discogs artist's name, a Discogs name variation, or the Discogs real name.
//
// Usage: node label-check.mjs ~/Downloads/discogs_20261001_artists.xml.gz   (run from the folder holding discogs-ids.qs.tsv)
// The dump is opened read-only and streamed.

import { createReadStream, readFileSync, writeFileSync } from "node:fs";
import { createGunzip } from "node:zlib";
import { setTimeout as sleep } from "node:timers/promises";
import { normalize, stripDiscogsSuffix } from "./normalize.mjs";
import { UA } from "./user-agent.mjs";

const dumpPath = process.argv[2];
const lines0 = readFileSync("discogs-ids.qs.tsv", "utf8").trim().split("\n");
const rows = lines0.map((line) => {
  const [qid, , discogsLit] = line.split("\t");
  return { line, qid, discogs: discogsLit.replace(/"/g, "") };
});
const wanted = new Set(rows.map((r) => r.discogs));

const decode = (s) =>
  s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&amp;/g, "&");

async function* lines(stream) {
  let buf = "";
  stream.setEncoding("utf8");
  for await (const chunk of stream) {
    buf += chunk;
    let i;
    while ((i = buf.indexOf("\n")) !== -1) {
      yield buf.slice(0, i);
      buf = buf.slice(i + 1);
    }
  }
  if (buf) yield buf;
}

// Discogs names
const discogs = new Map(); // id -> { name, nameNorm, otherNorm: normalized variations and real name }
for await (const line of lines(createReadStream(dumpPath, { flags: "r" }).pipe(createGunzip()))) {
  const id = line.match(/^<artist><id>(\d+)<\/id>/)?.[1];
  if (!id || !wanted.has(id)) continue;
  const name = decode(line.match(/<name>([^<]*)<\/name>/)?.[1] ?? "");
  const realname = decode(line.match(/<realname>([^<]*)<\/realname>/)?.[1] ?? "");
  const nv = line.match(/<namevariations>(.*?)<\/namevariations>/)?.[1] ?? "";
  const variations = [...nv.matchAll(/<name>([^<]*)<\/name>/g)].map((m) => decode(m[1]));
  discogs.set(id, { name, nameNorm: normalize(stripDiscogsSuffix(name)), otherNorm: new Set([realname, ...variations].filter(Boolean).map((v) => normalize(stripDiscogsSuffix(v)))) });
}
console.error(`Discogs artists found: ${discogs.size}/${wanted.size}`);

// Wikidata labels from QLever, one request at a time, 5s apart, backing off on 429 and 5xx
const labels = new Map();
for (let i = 0; i < rows.length; i += 5000) {
  await sleep(5000);
  const values = rows.slice(i, i + 5000).map((r) => `wd:${r.qid}`).join(" ");
  const query = `PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT ?item ?en ?mul WHERE {
  VALUES ?item { ${values} }
  OPTIONAL { ?item rdfs:label ?en . FILTER(LANG(?en) = "en") }
  OPTIONAL { ?item rdfs:label ?mul . FILTER(LANG(?mul) = "mul") }
}`;
  let res;
  for (let attempt = 0; ; attempt++) {
    res = await fetch("https://qlever.dev/api/wikidata", { method: "POST", headers: { "User-Agent": UA, Accept: "application/sparql-results+json", "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ query }) });
    if ((res.status !== 429 && res.status < 500) || attempt >= 5) break;
    const wait = Number(res.headers.get("retry-after")) || 60 * 2 ** attempt;
    console.error(`${res.status}, waiting ${wait}s`);
    await sleep(wait * 1000);
  }
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  for (const b of (await res.json()).results.bindings) {
    const label = b.en?.value ?? b.mul?.value ?? "";
    labels.set(b.item.value.split("/").pop(), { label, lang: b.en ? "en" : b.mul ? "mul" : "" });
  }
  console.error(`labels ${Math.min(i + 5000, rows.length)}/${rows.length}`);
}

const counts = { labelMatchesName: 0, labelMatchesVariationOrRealname: 0, mismatch: 0, noLabel: 0, notInDiscogsDump: 0 };
const kept = [];
const dropped = [];
for (const r of rows) {
  const d = discogs.get(r.discogs);
  const l = labels.get(r.qid) ?? { label: "", lang: "" };
  let result;
  if (!d) result = "notInDiscogsDump";
  else if (!l.label) result = "noLabel";
  else if (normalize(l.label) === d.nameNorm) result = "labelMatchesName";
  else if (d.otherNorm.has(normalize(l.label))) result = "labelMatchesVariationOrRealname";
  else result = "mismatch";
  counts[result]++;
  if (result.startsWith("labelMatches")) kept.push(r.line);
  else dropped.push([result, r.qid, l.label, l.lang, d?.name ?? "", r.discogs].map((v) => String(v).replace(/\s/g, " ")).join("\t"));
}

writeFileSync("discogs-ids.label-checked.qs.tsv", kept.join("\n") + "\n");
writeFileSync("discogs-ids.label-checked.first20.qs.tsv", kept.slice(0, 20).join("\n") + "\n");
writeFileSync("discogs-ids.label-checked.rest.qs.tsv", kept.slice(20).join("\n") + "\n");
writeFileSync("discogs-ids.label-dropped.tsv", ["result\tqid\twdLabel\twdLabelLang\tdiscogsName\tdiscogs", ...dropped].join("\n") + "\n");
console.log({ input: rows.length, kept: kept.length, ...counts });
