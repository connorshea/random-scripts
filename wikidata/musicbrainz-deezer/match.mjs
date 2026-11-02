// Step 2: match Wikidata items to Deezer artist IDs through the MusicBrainz artist dump.
//
// Usage: node match.mjs [path/to/artist.tar.xz] [dir]
//   The dump defaults to ~/Downloads/artist.tar.xz. It's streamed out of the archive with
//   `tar -xOJf <dump> mbdump/artist`, so it never has to be unpacked.
//   Reads <dir>/wd-mb.tsv and <dir>/wd-deezer.tsv (from fetch-wikidata.mjs). Writes
//   <dir>/candidates.tsv (qid, mbid, deezer, mbName) and <dir>/match-skipped.tsv.
//
// A pair is kept only when it's one-to-one all the way through:
//   - the MusicBrainz artist has exactly one Deezer link (ended links are ignored), and no other
//     MusicBrainz artist links to that Deezer ID
//   - the MBID is on exactly one Wikidata item, and that item has no other MBID (deprecated
//     statements are ignored on both counts)
//   - if the MusicBrainz artist links to Wikidata, the link points at the same item
//   - the item has no Deezer artist ID (P2722) of any rank, and the Deezer ID isn't on any other item

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { readTsv, writeTsv, groupBy } from "./common.mjs";

const dump = process.argv[2] ?? join(homedir(), "Downloads", "artist.tar.xz");
const dir = process.argv[3] ?? ".";

// Wikidata side
const mbRows = readTsv(join(dir, "wd-mb.tsv")).filter((r) => r.rank !== "deprecated");
const mbidToItems = groupBy(mbRows, "mbid", (r) => r.qid);
const itemToMbids = groupBy(mbRows, "qid", (r) => r.mbid);
const deezerRows = readTsv(join(dir, "wd-deezer.tsv"));
const itemToDeezer = groupBy(deezerRows, "qid", (r) => r.deezer);
const deezerToItems = groupBy(deezerRows, "deezer", (r) => r.qid);

// MusicBrainz side. Split on \n only: some annotations contain a raw \r, which readline would treat
// as a line break.
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

// https://www.deezer.com/artist/27, with an optional locale (/en/, /fr/, /us/), the api. host, and
// a query string like ?autoplay=true. Not /artist/27/image or links wrapped in a redirect.
const DEEZER_URL = /^https?:\/\/(?:www\.|api\.)?deezer\.com\/(?:[a-z]{2}(?:-[a-z]{2})?\/)?artist\/(\d+)\/?(?:\?.*)?$/i;
const tar = spawn("tar", ["-xOJf", dump, "mbdump/artist"], { stdio: ["ignore", "pipe", "inherit"] });
const tarExit = new Promise((resolve) => tar.on("close", resolve));

const artists = []; // MusicBrainz artists with at least one current Deezer link
const deezerToMb = new Map(); // Deezer ID -> Set of MBIDs linking to it
let read = 0;
let unparsedLinks = 0;
for await (const line of lines(tar.stdout)) {
  if (++read % 500_000 === 0) console.error(`${read} artists read`);
  if (!line.includes("deezer.com")) continue;
  // Raw control characters aren't valid inside JSON strings
  const a = JSON.parse(line.replace(/[\u0000-\u001f]/g, " "));
  const deezer = new Set();
  const wikidata = new Set();
  for (const rel of a.relations ?? []) {
    if (rel["target-type"] !== "url" || rel.ended) continue;
    const url = rel.url?.resource ?? "";
    if (url.includes("deezer.com/")) {
      const id = url.match(DEEZER_URL)?.[1];
      if (id) deezer.add(id);
      else if (/deezer\.com\/(?:[a-z-]+\/)?artist\//.test(url)) unparsedLinks++;
    } else if (rel.type === "wikidata") {
      const qid = url.match(/wikidata\.org\/wiki\/(Q\d+)/)?.[1];
      if (qid) wikidata.add(qid);
    }
  }
  if (deezer.size === 0) continue;
  artists.push({ mbid: a.id, name: a.name, deezer: [...deezer], wikidata: [...wikidata] });
  for (const id of deezer) (deezerToMb.get(id) ?? deezerToMb.set(id, new Set()).get(id)).add(a.id);
}
const code = await tarExit;
if (code !== 0 || read === 0) {
  console.error(`tar exited with code ${code} after ${read} lines. Is the archive complete, and does it contain mbdump/artist?`);
  process.exit(1);
}

const candidates = [];
const skipped = [];
const counts = {};
let alreadyOnItem = 0;
const skip = (row, reason) => {
  skipped.push({ ...row, reason });
  counts[reason] = (counts[reason] ?? 0) + 1;
};
for (const a of artists) {
  const items = mbidToItems.get(a.mbid);
  if (!items) continue; // not on Wikidata, nothing to add to
  const row = { mbid: a.mbid, mbName: a.name, deezer: a.deezer.join(","), qid: items.join(",") };
  if (items.length > 1) { skip(row, "MBID on more than one item"); continue; }
  const qid = items[0];
  const itemDeezer = itemToDeezer.get(qid) ?? [];
  if (a.deezer.length === 1 && itemDeezer.includes(a.deezer[0])) { alreadyOnItem++; continue; }
  if (a.deezer.length > 1) { skip(row, "MusicBrainz artist has more than one Deezer link"); continue; }
  const deezer = a.deezer[0];
  if (deezerToMb.get(deezer).size > 1) { skip(row, "Deezer ID linked from more than one MusicBrainz artist"); continue; }
  if (itemToMbids.get(qid).length > 1) { skip(row, "item has more than one MBID"); continue; }
  if (a.wikidata.length && !(a.wikidata.length === 1 && a.wikidata[0] === qid)) {
    skip({ ...row, detail: a.wikidata.join(",") }, "MusicBrainz artist links to a different Wikidata item");
    continue;
  }
  if (itemDeezer.length) { skip({ ...row, detail: itemDeezer.join(",") }, "item already has a different Deezer ID"); continue; }
  if (deezerToItems.has(deezer)) { skip({ ...row, detail: deezerToItems.get(deezer).join(",") }, "Deezer ID already on another item"); continue; }
  candidates.push({ qid, mbid: a.mbid, deezer, mbName: a.name });
}

writeTsv(join(dir, "candidates.tsv"), ["qid", "mbid", "deezer", "mbName"], candidates);
writeTsv(join(dir, "match-skipped.tsv"), ["qid", "mbid", "deezer", "mbName", "reason", "detail"], skipped);
console.error(
  JSON.stringify(
    {
      mbArtists: read,
      mbArtistsWithDeezer: artists.length,
      unparsedDeezerArtistLinks: unparsedLinks,
      alreadyOnItem,
      skipped: counts,
      candidates: candidates.length,
    },
    null,
    2,
  ),
);
