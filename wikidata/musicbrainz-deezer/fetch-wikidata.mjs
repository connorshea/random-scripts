// Step 1: query QLever for every MusicBrainz artist ID (P434) and every Deezer artist ID (P2722) on
// Wikidata.
//
// Usage: CONTACT_EMAIL=you@example.com node fetch-wikidata.mjs [out-dir]
// Writes:
//   <out-dir>/wd-mb.tsv      qid, mbid, rank: every P434 statement
//   <out-dir>/wd-deezer.tsv  qid, deezer, rank: every P2722 statement

import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { qlever, qidOf, writeTsv } from "./common.mjs";

const outDir = process.argv[2] ?? ".";

const PREFIXES = `PREFIX p: <http://www.wikidata.org/prop/>
PREFIX ps: <http://www.wikidata.org/prop/statement/>
PREFIX wikibase: <http://wikiba.se/ontology#>
`;
const rankName = (uri) => ({ PreferredRank: "preferred", NormalRank: "normal", DeprecatedRank: "deprecated" })[uri.split("#").pop()] ?? uri;

for (const [prop, file, col] of [["P434", "wd-mb.tsv", "mbid"], ["P2722", "wd-deezer.tsv", "deezer"]]) {
  const rows = (await qlever(`${PREFIXES}
SELECT ?item ?value ?rank WHERE {
  ?item p:${prop} ?st .
  ?st ps:${prop} ?value ;
      wikibase:rank ?rank .
}`)).map((b) => ({
    qid: qidOf(b.item.value),
    [col]: col === "mbid" ? b.value.value.toLowerCase() : b.value.value,
    rank: rankName(b.rank.value),
  }));
  writeTsv(join(outDir, file), ["qid", col, "rank"], rows);
  console.error(`${rows.length} ${prop} statements -> ${file}`);
  await sleep(5000);
}
