// Match MusicBrainz artists to Wikidata items through their Discogs artist IDs.
//
// Usage:
//   tar -xOJf ~/Downloads/artist.tar.xz mbdump/artist | node match.mjs wd-discogs-no-mb.tsv > candidates.json
//
// stdin: the MusicBrainz JSON artist dump, one artist per line.
// argv[2]: WDQS TSV of ?item ?discogs for items with a Discogs artist ID (P1953) and no MusicBrainz artist ID (P434).
//
// A pair is kept only when the link is one-to-one on both sides:
// - the Wikidata item has exactly one Discogs ID, and no other item in the TSV has that ID
// - the MusicBrainz artist has exactly one Discogs link, and no other MusicBrainz artist links to that ID
// - if the MusicBrainz artist links to Wikidata, the link points at the same item

import { readFileSync } from "node:fs";

const tsvPath = process.argv[2];
if (!tsvPath) {
  console.error("usage: node match.mjs <wd-discogs-no-mb.tsv> < mbdump/artist");
  process.exit(1);
}

// Wikidata side
const itemToDiscogs = new Map();
const discogsToItems = new Map();
for (const line of readFileSync(tsvPath, "utf8").split("\n").slice(1)) {
  if (!line.trim()) continue;
  const [itemIri, discogsLit] = line.split("\t");
  const qid = itemIri.match(/(Q\d+)>$/)?.[1];
  const discogs = discogsLit?.match(/^"(.*)"$/)?.[1];
  if (!qid || !discogs) continue;
  if (!itemToDiscogs.has(qid)) itemToDiscogs.set(qid, new Set());
  itemToDiscogs.get(qid).add(discogs);
  if (!discogsToItems.has(discogs)) discogsToItems.set(discogs, new Set());
  discogsToItems.get(discogs).add(qid);
}

// MusicBrainz side
const discogsToMb = new Map(); // discogs ID -> MB artists linking to it (only IDs present on Wikidata)
const stats = { mbArtists: 0, mbWithDiscogs: 0, mbMultipleDiscogs: 0 };

// Split on \n only: some annotations contain raw \r, which readline would treat as a line break
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

for await (const line of lines(process.stdin)) {
  if (!line.trim()) continue;
  stats.mbArtists++;
  // Raw control characters aren't valid inside JSON strings
  const artist = JSON.parse(line.replace(/[\u0000-\u001f]/g, " "));
  const discogsIds = new Set();
  const wikidataQids = new Set();
  for (const rel of artist.relations ?? []) {
    if (rel["target-type"] !== "url") continue;
    const url = rel.url?.resource ?? "";
    if (rel.type === "discogs") {
      const id = url.match(/discogs\.com\/artist\/(\d+)/)?.[1];
      if (id) discogsIds.add(id);
    } else if (rel.type === "wikidata") {
      const qid = url.match(/wikidata\.org\/wiki\/(Q\d+)/)?.[1];
      if (qid) wikidataQids.add(qid);
    }
  }
  if (discogsIds.size === 0) continue;
  stats.mbWithDiscogs++;
  if (discogsIds.size > 1) stats.mbMultipleDiscogs++;
  for (const id of discogsIds) {
    if (!discogsToItems.has(id)) continue;
    if (!discogsToMb.has(id)) discogsToMb.set(id, []);
    discogsToMb.get(id).push({
      mbid: artist.id,
      name: artist.name,
      disambiguation: artist.disambiguation ?? "",
      discogsCount: discogsIds.size,
      wikidataQids: [...wikidataQids],
    });
  }
}

const drops = {
  wdMultipleDiscogs: 0,
  wdDiscogsSharedByItems: 0,
  mbMultipleDiscogs: 0,
  mbDiscogsSharedByArtists: 0,
  mbLinksOtherWikidataItem: 0,
};
const candidates = [];
for (const [discogs, mbArtists] of discogsToMb) {
  const items = [...discogsToItems.get(discogs)];
  if (items.length > 1) {
    drops.wdDiscogsSharedByItems++;
    continue;
  }
  const qid = items[0];
  if (itemToDiscogs.get(qid).size > 1) {
    drops.wdMultipleDiscogs++;
    continue;
  }
  if (mbArtists.length > 1) {
    drops.mbDiscogsSharedByArtists++;
    continue;
  }
  const mb = mbArtists[0];
  if (mb.discogsCount > 1) {
    drops.mbMultipleDiscogs++;
    continue;
  }
  if (mb.wikidataQids.length > 0 && !(mb.wikidataQids.length === 1 && mb.wikidataQids[0] === qid)) {
    drops.mbLinksOtherWikidataItem++;
    continue;
  }
  candidates.push({ qid, discogs, mbid: mb.mbid, mbName: mb.name, mbDisambiguation: mb.disambiguation, mbLinksThisItem: mb.wikidataQids.length === 1 });
}

console.error(JSON.stringify({ wdItems: itemToDiscogs.size, ...stats, discogsIdsMatched: discogsToMb.size, drops, candidates: candidates.length }, null, 2));
process.stdout.write(JSON.stringify(candidates, null, 1));
