// Find Discogs artist IDs (P1953) we could add to Wikidata items that have a MusicBrainz artist ID (P434)
// but no Discogs ID, using the Discogs links in the MusicBrainz artist dump.
//
// Usage:
//   tar -xOJf ~/Downloads/artist.tar.xz mbdump/artist | node reverse-match.mjs wd-mb-no-discogs.tsv wd-all-discogs.tsv > reverse-candidates.json
//
// A pair is kept only when:
// - the Wikidata item has exactly one MusicBrainz ID, and no other item in the TSV has that MusicBrainz ID
// - the MusicBrainz artist has exactly one Discogs link, and no other MusicBrainz artist links to that Discogs ID
// - the Discogs ID isn't already on any Wikidata item
// - if the MusicBrainz artist links to Wikidata, the link points at the same item

import { readFileSync } from "node:fs";

const [itemsPath, allDiscogsPath] = process.argv.slice(2);

const itemToMb = new Map();
const mbToItems = new Map();
for (const line of readFileSync(itemsPath, "utf8").split("\n").slice(1)) {
  const m = line.match(/(Q\d+)>\t"(.*)"$/);
  if (!m) continue;
  const [, qid, mbid] = m;
  (itemToMb.get(qid) ?? itemToMb.set(qid, new Set()).get(qid)).add(mbid);
  (mbToItems.get(mbid) ?? mbToItems.set(mbid, new Set()).get(mbid)).add(qid);
}
const discogsOnWikidata = new Set();
for (const line of readFileSync(allDiscogsPath, "utf8").split("\n").slice(1)) {
  const m = line.match(/^"(.*)"$/);
  if (m) discogsOnWikidata.add(m[1]);
}

// Split on \n only: some annotations contain raw \r
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

const discogsToMbCount = new Map(); // across every MB artist, for the "shared by two MB artists" check
const hits = []; // MB artists whose MBID is on one of our Wikidata items
let mbArtists = 0;
for await (const line of lines(process.stdin)) {
  if (!line.trim()) continue;
  mbArtists++;
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
  for (const id of discogsIds) discogsToMbCount.set(id, (discogsToMbCount.get(id) ?? 0) + 1);
  if (mbToItems.has(artist.id)) hits.push({ mbid: artist.id, name: artist.name, discogsIds: [...discogsIds], wikidataQids: [...wikidataQids] });
}

const drops = {
  mbNoDiscogs: 0,
  wdMbSharedByItems: 0,
  wdMultipleMb: 0,
  mbMultipleDiscogs: 0,
  discogsSharedByMbArtists: 0,
  discogsAlreadyOnWikidata: 0,
  mbLinksOtherWikidataItem: 0,
};
const candidates = [];
for (const h of hits) {
  if (h.discogsIds.length === 0) { drops.mbNoDiscogs++; continue; }
  const items = [...mbToItems.get(h.mbid)];
  if (items.length > 1) { drops.wdMbSharedByItems++; continue; }
  const qid = items[0];
  if (itemToMb.get(qid).size > 1) { drops.wdMultipleMb++; continue; }
  if (h.discogsIds.length > 1) { drops.mbMultipleDiscogs++; continue; }
  const discogs = h.discogsIds[0];
  if (discogsToMbCount.get(discogs) > 1) { drops.discogsSharedByMbArtists++; continue; }
  if (discogsOnWikidata.has(discogs)) { drops.discogsAlreadyOnWikidata++; continue; }
  if (h.wikidataQids.length > 0 && !(h.wikidataQids.length === 1 && h.wikidataQids[0] === qid)) { drops.mbLinksOtherWikidataItem++; continue; }
  candidates.push({ qid, mbid: h.mbid, mbName: h.name, discogs });
}

console.error(JSON.stringify({ wdItems: itemToMb.size, discogsOnWikidata: discogsOnWikidata.size, mbArtists, mbidsFoundInDump: hits.length, drops, candidates: candidates.length }, null, 2));
process.stdout.write(JSON.stringify(candidates, null, 1));
