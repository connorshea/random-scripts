// Compare the Discogs name of each reverse-match candidate with its MusicBrainz name.
//
// Usage: node discogs-names.mjs ~/Downloads/discogs_20261001_artists.xml.gz reverse-candidates.json
// Writes reverse-name-check.tsv next to the candidates file.
// The dump is opened read-only and streamed through gunzip, nothing is written next to it.

import { createReadStream, readFileSync, writeFileSync } from "node:fs";
import { createGunzip } from "node:zlib";
import { dirname, join } from "node:path";
import { normalize, stripDiscogsSuffix } from "./normalize.mjs";

const [dumpPath, candidatesPath] = process.argv.slice(2);
const candidates = JSON.parse(readFileSync(candidatesPath, "utf8"));
const wanted = new Set(candidates.map((c) => c.discogs));

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

const discogs = new Map(); // id -> { name, realname, variations }
for await (const line of lines(createReadStream(dumpPath, { flags: "r" }).pipe(createGunzip()))) {
  const id = line.match(/^<artist><id>(\d+)<\/id>/)?.[1];
  if (!id || !wanted.has(id)) continue;
  const name = decode(line.match(/<name>([^<]*)<\/name>/)?.[1] ?? "");
  const realname = decode(line.match(/<realname>([^<]*)<\/realname>/)?.[1] ?? "");
  const nv = line.match(/<namevariations>(.*?)<\/namevariations>/)?.[1] ?? "";
  const variations = [...nv.matchAll(/<name>([^<]*)<\/name>/g)].map((m) => decode(m[1]));
  discogs.set(id, { name, realname, variations });
}

const counts = { nameMatch: 0, variationOrRealnameMatch: 0, mismatch: 0, notInDiscogsDump: 0 };
const rows = [];
for (const c of candidates) {
  const d = discogs.get(c.discogs);
  let result;
  if (!d) result = "notInDiscogsDump";
  else if (normalize(stripDiscogsSuffix(d.name)) === normalize(c.mbName)) result = "nameMatch";
  else if ([d.realname, ...d.variations].filter(Boolean).some((v) => normalize(stripDiscogsSuffix(v)) === normalize(c.mbName))) result = "variationOrRealnameMatch";
  else result = "mismatch";
  counts[result]++;
  rows.push([result, c.qid, c.mbid, c.mbName, c.discogs, d?.name ?? ""].map((v) => String(v).replace(/\s/g, " ")).join("\t"));
}
writeFileSync(join(dirname(candidatesPath), "reverse-name-check.tsv"), ["result\tqid\tmbid\tmbName\tdiscogs\tdiscogsName", ...rows].join("\n") + "\n");
console.log({ candidates: candidates.length, foundInDiscogs: discogs.size, ...counts });
