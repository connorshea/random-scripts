// Step 1: query QLever for the items to fill in and for every ISWC already on Wikidata.
//
// Usage: CONTACT_EMAIL=you@example.com node fetch-candidates.mjs [out-dir]
// Writes:
//   <out-dir>/candidates.tsv      qid, mbid: items whose only instance of (P31) is musical
//                                 work/composition (Q105543609), with a MusicBrainz work ID (P435)
//                                 and no ISWC (P1827) of any rank. One row per MBID.
//   <out-dir>/existing-iswcs.tsv  iswc, qid: every ISWC on Wikidata, normalized to T-123.456.789-0,
//                                 so the batch doesn't add an ISWC that's already on another item.

import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { qlever, qidOf, canonicalizeIswc, writeTsv } from "./common.mjs";

const outDir = process.argv[2] ?? ".";

const PREFIXES = `PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX p: <http://www.wikidata.org/prop/>
PREFIX ps: <http://www.wikidata.org/prop/statement/>
`;

// wdt:P435 only has best-rank values, so deprecated MusicBrainz IDs aren't used. p:P1827 matches
// ISWC statements of every rank, so items with only a deprecated ISWC are left alone too.
const candidates = await qlever(`${PREFIXES}
SELECT DISTINCT ?item ?mbid WHERE {
  ?item wdt:P31 wd:Q105543609 ;
        wdt:P435 ?mbid .
  FILTER NOT EXISTS { ?item p:P1827 [] }
  FILTER NOT EXISTS { ?item wdt:P31 ?other . FILTER(?other != wd:Q105543609) }
}`);
const candRows = candidates.map((b) => ({ qid: qidOf(b.item.value), mbid: b.mbid.value.toLowerCase() }));
writeTsv(join(outDir, "candidates.tsv"), ["qid", "mbid"], candRows);
console.error(`${new Set(candRows.map((r) => r.qid)).size} items, ${candRows.length} MBIDs -> candidates.tsv`);

await sleep(5000);

const existing = await qlever(`${PREFIXES}
SELECT ?item ?iswc WHERE { ?item p:P1827/ps:P1827 ?iswc }`);
const existingRows = existing.map((b) => ({
  iswc: canonicalizeIswc(b.iswc.value) ?? b.iswc.value,
  qid: qidOf(b.item.value),
}));
writeTsv(join(outDir, "existing-iswcs.tsv"), ["iswc", "qid"], existingRows);
console.error(`${existingRows.length} existing ISWC statements -> existing-iswcs.tsv`);
