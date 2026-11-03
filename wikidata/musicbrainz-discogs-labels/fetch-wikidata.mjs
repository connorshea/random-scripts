// Step 1: query QLever for every MusicBrainz label ID (P966) and every Discogs label ID (P1955) on
// Wikidata.
//
// Usage: CONTACT_EMAIL=you@example.com node fetch-wikidata.mjs [out-dir]
//   Files that already exist are kept, so delete them to refetch.
// Writes:
//   <out-dir>/wd-mb.tsv       qid, mbid, rank: every P966 statement (MBIDs lowercased)
//   <out-dir>/wd-discogs.tsv  qid, discogs, rank: every P1955 statement

import { existsSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { qlever, qidOf, writeTsv } from "./common.mjs";

const outDir = process.argv[2] ?? ".";

const PREFIXES = `PREFIX p: <http://www.wikidata.org/prop/>
PREFIX ps: <http://www.wikidata.org/prop/statement/>
PREFIX wikibase: <http://wikiba.se/ontology#>
`;
const rankName = (uri) => ({ PreferredRank: "preferred", NormalRank: "normal", DeprecatedRank: "deprecated" })[uri.split("#").pop()] ?? uri;

let first = true;
for (const [prop, file, col] of [["P966", "wd-mb.tsv", "mbid"], ["P1955", "wd-discogs.tsv", "discogs"]]) {
  if (existsSync(join(outDir, file))) { console.error(`${file} exists, skipping`); continue; }
  if (!first) await sleep(60_000); // be gentle with QLever: one query a minute
  first = false;
  const rows = (await qlever(`${PREFIXES}
SELECT ?item ?value ?rank WHERE {
  ?item p:${prop} ?st .
  ?st ps:${prop} ?value ;
      wikibase:rank ?rank .
}`))
    .filter((b) => b.value.type === "literal") // skip somevalue
    .map((b) => ({
      qid: qidOf(b.item.value),
      [col]: col === "mbid" ? b.value.value.toLowerCase() : b.value.value,
      rank: rankName(b.rank.value),
    }));
  writeTsv(join(outDir, file), ["qid", col, "rank"], rows);
  console.error(`${rows.length} ${prop} statements -> ${file}`);
}
