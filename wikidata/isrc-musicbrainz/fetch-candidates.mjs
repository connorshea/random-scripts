// Step 1: query QLever for the items to fill in and for every ISRC already on Wikidata.
//
// Usage: CONTACT_EMAIL=you@example.com node fetch-candidates.mjs [out-dir]
// Writes:
//   <out-dir>/candidates.tsv      qid, mbid: items whose every instance of (P31) is a track type
//                                 (music track with vocals Q55850593, music track without lyrics
//                                 Q55850643, audio track Q7302866), with a MusicBrainz recording ID
//                                 (P4404), and with no ISRC (P1243), MusicBrainz work ID (P435) or
//                                 ISWC (P1827) of any rank. One row per MBID.
//   <out-dir>/existing-isrcs.tsv  isrc, qid: every ISRC on Wikidata (uppercase, without hyphens), so
//                                 the batch doesn't add one that's already on another item.

import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { qlever, qidOf, canonicalizeIsrc, writeTsv, TRACK_TYPES } from "./common.mjs";

const outDir = process.argv[2] ?? ".";

const PREFIXES = `PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX p: <http://www.wikidata.org/prop/>
PREFIX ps: <http://www.wikidata.org/prop/statement/>
`;
const types = TRACK_TYPES.map((t) => `wd:${t}`).join(", ");

// wdt:P4404 and wdt:P31 only have best-rank values, so deprecated ones aren't used. p:P1243 etc.
// match statements of every rank, so items with only a deprecated ISRC are left alone too.
const candidates = await qlever(`${PREFIXES}
SELECT DISTINCT ?item ?mbid WHERE {
  ?item wdt:P4404 ?mbid ;
        wdt:P31 ?type .
  FILTER(?type IN (${types}))
  FILTER NOT EXISTS { ?item p:P1243 [] }
  FILTER NOT EXISTS { ?item p:P435 [] }
  FILTER NOT EXISTS { ?item p:P1827 [] }
  FILTER NOT EXISTS { ?item wdt:P31 ?other . FILTER(?other NOT IN (${types})) }
}`);
const candRows = candidates.map((b) => ({ qid: qidOf(b.item.value), mbid: b.mbid.value.toLowerCase() }));
writeTsv(join(outDir, "candidates.tsv"), ["qid", "mbid"], candRows);
console.error(`${new Set(candRows.map((r) => r.qid)).size} items, ${candRows.length} MBIDs -> candidates.tsv`);

await sleep(5000);

const existing = await qlever(`${PREFIXES}
SELECT ?item ?isrc WHERE { ?item p:P1243/ps:P1243 ?isrc }`);
const existingRows = existing
  .filter((b) => b.isrc.type === "literal") // skip somevalue
  .map((b) => ({ isrc: canonicalizeIsrc(b.isrc.value) ?? b.isrc.value, qid: qidOf(b.item.value) }));
writeTsv(join(outDir, "existing-isrcs.tsv"), ["isrc", "qid"], existingRows);
console.error(`${existingRows.length} existing ISRC statements -> existing-isrcs.tsv`);
