// Step 3: get the Discogs name of each candidate's Discogs label from the Discogs labels dump.
//
// Usage: node discogs-names.mjs path/to/discogs_YYYYMMDD_labels.xml.gz [dir]
//   The dump (from https://data.discogs.com/) is opened read-only and streamed through gunzip.
//   Reads <dir>/candidates.tsv and writes <dir>/discogs-labels.tsv (discogs, name). Candidates whose
//   Discogs ID isn't in the dump get no row.
//
// Each top-level label in the dump starts a line with <label><id>N</id><name>…</name>. Sublabels
// and parent labels are written as <label id="N">, so they don't match.

import { createReadStream } from "node:fs";
import { createGunzip } from "node:zlib";
import { join } from "node:path";
import { readTsv, writeTsv, lines } from "./common.mjs";

const [dumpPath, dir = "."] = process.argv.slice(2);
if (!dumpPath) {
  console.error("Usage: node discogs-names.mjs path/to/discogs_YYYYMMDD_labels.xml.gz [dir]");
  process.exit(1);
}
const wanted = new Set(readTsv(join(dir, "candidates.tsv")).map((c) => c.discogs));

const decode = (s) =>
  s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&amp;/g, "&");

const rows = [];
let labels = 0;
for await (const line of lines(createReadStream(dumpPath, { flags: "r" }).pipe(createGunzip()))) {
  const m = line.match(/^<label><id>(\d+)<\/id><name>([^<]*)<\/name>/);
  if (!m) continue;
  if (++labels % 500_000 === 0) console.error(`${labels} Discogs labels read`);
  if (wanted.has(m[1])) rows.push({ discogs: m[1], name: decode(m[2]) });
}
if (labels === 0) {
  console.error("no labels read. Is this the labels dump?");
  process.exit(1);
}
writeTsv(join(dir, "discogs-labels.tsv"), ["discogs", "name"], rows);
console.error(`${labels} Discogs labels in dump; ${rows.length}/${wanted.size} candidate IDs found -> discogs-labels.tsv`);
