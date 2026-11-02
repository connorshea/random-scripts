// Step 2: pull the ISWCs for the candidate MBIDs out of the MusicBrainz JSON work dump.
//
// Usage: node extract-iswcs.mjs [path/to/work.tar.xz] [dir]
//   The dump defaults to ~/Downloads/work.tar.xz. It's streamed out of the archive with
//   `tar -xOJf <dump> mbdump/work`, so it never has to be unpacked or written anywhere.
//   Reads <dir>/candidates.tsv (from fetch-candidates.mjs) and writes <dir>/mb-works.tsv:
//     mbid, title, iswcs (comma-separated), wikidata (QIDs the MusicBrainz work links to, comma-separated)
//   Every candidate MBID found in the dump gets a row, including works without ISWCs.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { join } from "node:path";
import { readTsv, writeTsv } from "./common.mjs";

const dump = process.argv[2] ?? join(homedir(), "Downloads", "work.tar.xz");
const dir = process.argv[3] ?? ".";

const wanted = new Set(readTsv(join(dir, "candidates.tsv")).map((r) => r.mbid));
console.error(`looking for ${wanted.size} MBIDs in ${dump}`);

const tar = spawn("tar", ["-xOJf", dump, "mbdump/work"], { stdio: ["ignore", "pipe", "inherit"] });
const tarExit = new Promise((resolve) => tar.on("close", resolve));

const rows = [];
let lines = 0;
for await (const line of createInterface({ input: tar.stdout, crlfDelay: Infinity })) {
  if (++lines % 500_000 === 0) console.error(`${lines} works read, ${rows.length} found`);
  // Cheap pre-filter before parsing: the line has to contain one of the wanted MBIDs somewhere. The
  // work's own id isn't necessarily the first UUID in the line, so check every one.
  let hit = false;
  for (const m of line.matchAll(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g)) {
    if (wanted.has(m[0])) { hit = true; break; }
  }
  if (!hit) continue;
  const work = JSON.parse(line);
  if (!wanted.has(work.id)) continue;
  const wikidata = (work.relations ?? [])
    .filter((r) => r.type === "wikidata" && r.url?.resource)
    .map((r) => r.url.resource.split("/").pop());
  rows.push({ mbid: work.id, title: work.title, iswcs: (work.iswcs ?? []).join(","), wikidata: wikidata.join(",") });
}

const code = await tarExit;
if (code !== 0) {
  console.error(`tar exited with code ${code}. Is the download complete, and does the archive contain mbdump/work?`);
  process.exit(1);
}
if (lines === 0) {
  console.error("no lines read from the dump");
  process.exit(1);
}

writeTsv(join(dir, "mb-works.tsv"), ["mbid", "title", "iswcs", "wikidata"], rows);
const withIswc = rows.filter((r) => r.iswcs).length;
console.error(
  `${lines} works in dump; ${rows.length}/${wanted.size} candidate MBIDs found, ${withIswc} with at least one ISWC -> mb-works.tsv`,
);
