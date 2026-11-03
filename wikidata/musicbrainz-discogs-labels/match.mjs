// Step 2: match Wikidata items to MusicBrainz labels through the MusicBrainz label dump, in both
// directions.
//
// Usage: node match.mjs [path/to/label.tar.xz] [dir]
//   The dump defaults to ~/Downloads/label.tar.xz. It's streamed out of the archive with
//   `tar -xOJf <dump> mbdump/label`, so it never has to be unpacked.
//   Reads <dir>/wd-mb.tsv and <dir>/wd-discogs.tsv (from fetch-wikidata.mjs). Writes:
//     <dir>/candidates.tsv     direction, qid, mbid, discogs, mbName. direction is "discogs" (add
//                              P1955 to an item that has the P966) or "mb" (add P966 to an item
//                              that has the P1955).
//     <dir>/match-skipped.tsv  pairs left out, with the reason
//
// In both directions a pair is kept only when it's one-to-one all the way through:
//   - the MusicBrainz label has exactly one Discogs label link (ended links are ignored), and no
//     other MusicBrainz label links to that Discogs ID
//   - if the MusicBrainz label links to Wikidata, the link points at the same item
//   - deprecated statements are ignored when counting IDs on an item, but any statement of the
//     property being added (any rank) counts as the item already having it
// Discogs IDs (adding P1955 to an item with P966):
//   - the MBID is on exactly one item, and that item has no other MBID
//   - the item has no Discogs label ID, and the Discogs ID isn't on any other item
// MusicBrainz IDs (adding P966 to an item with P1955):
//   - the Discogs ID is on exactly one item, and that item has no other Discogs label ID
//   - the item has no MusicBrainz label ID, and the MBID isn't on any other item

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { readTsv, writeTsv, groupBy, lines } from "./common.mjs";

const dump = process.argv[2] ?? join(homedir(), "Downloads", "label.tar.xz");
const dir = process.argv[3] ?? ".";

// Wikidata side. A few P1955 values aren't plain IDs (e.g. "LC 6730"); compare URLs by the ID in them.
const discogsIdOf = (v) => v.match(/discogs\.com\/(?:[a-z]{2}\/)?label\/(\d+)/)?.[1] ?? v;
const mbAll = readTsv(join(dir, "wd-mb.tsv"));
const dAll = readTsv(join(dir, "wd-discogs.tsv")).map((r) => ({ ...r, discogs: discogsIdOf(r.discogs) }));
const live = (rows) => rows.filter((r) => r.rank !== "deprecated");
const mbidToItems = groupBy(live(mbAll), "mbid", (r) => r.qid);
const itemToMbids = groupBy(live(mbAll), "qid", (r) => r.mbid);
const mbidAnyRank = groupBy(mbAll, "mbid", (r) => r.qid);
const itemMbidAnyRank = groupBy(mbAll, "qid", (r) => r.mbid);
const discogsToItems = groupBy(live(dAll), "discogs", (r) => r.qid);
const itemToDiscogs = groupBy(live(dAll), "qid", (r) => r.discogs);
const discogsAnyRank = groupBy(dAll, "discogs", (r) => r.qid);
const itemDiscogsAnyRank = groupBy(dAll, "qid", (r) => r.discogs);

// https://www.discogs.com/label/67467, optionally with a slug (/label/67467-Name), a language
// prefix (/fr/label/…), a trailing slash or a query string.
const DISCOGS_URL = /^https?:\/\/(?:www\.)?discogs\.com\/(?:[a-z]{2}\/)?label\/(\d+)(?:-[^/?#]*)?\/?(?:[?#].*)?$/i;
const tar = spawn("tar", ["-xOJf", dump, "mbdump/label"], { stdio: ["ignore", "pipe", "inherit"] });
const tarExit = new Promise((resolve) => tar.on("close", resolve));

const labels = []; // MusicBrainz labels with at least one current Discogs label link
const discogsToMb = new Map(); // Discogs ID -> Set of MBIDs linking to it
let read = 0;
let unparsedLinks = 0;
for await (const line of lines(tar.stdout)) {
  if (++read % 100_000 === 0) console.error(`${read} labels read`);
  if (!line.includes("discogs.com")) continue;
  // Raw control characters aren't valid inside JSON strings
  const l = JSON.parse(line.replace(/[\u0000-\u001f]/g, " "));
  const discogs = new Set();
  const wikidata = new Set();
  for (const rel of l.relations ?? []) {
    if (rel["target-type"] !== "url" || rel.ended) continue;
    const url = rel.url?.resource ?? "";
    if (rel.type === "discogs") {
      const id = url.match(DISCOGS_URL)?.[1];
      if (id) discogs.add(id);
      else unparsedLinks++;
    } else if (rel.type === "wikidata") {
      const qid = url.match(/wikidata\.org\/wiki\/(Q\d+)/)?.[1];
      if (qid) wikidata.add(qid);
    }
  }
  if (discogs.size === 0) continue;
  labels.push({ mbid: l.id, name: l.name, discogs: [...discogs], wikidata: [...wikidata] });
  for (const id of discogs) (discogsToMb.get(id) ?? discogsToMb.set(id, new Set()).get(id)).add(l.id);
}
const code = await tarExit;
if (code !== 0 || read === 0) {
  console.error(`tar exited with code ${code} after ${read} lines. Is the archive complete, and does it contain mbdump/label?`);
  process.exit(1);
}

const candidates = [];
const skipped = [];
const counts = { discogs: {}, mb: {} };
const alreadyLinked = { discogs: 0, mb: 0 };
const skip = (direction, row, reason, detail = "") => {
  skipped.push({ direction, ...row, reason, detail });
  counts[direction][reason] = (counts[direction][reason] ?? 0) + 1;
};

// Checks on the MusicBrainz side, shared by both directions: [reason, detail] or null.
function mbSideProblem(l, qid) {
  if (l.discogs.length > 1) return ["MusicBrainz label has more than one Discogs label link", l.discogs.join(",")];
  const linkers = discogsToMb.get(l.discogs[0]);
  if (linkers.size > 1) return ["Discogs ID linked from more than one MusicBrainz label", [...linkers].join(",")];
  if (l.wikidata.length && !(l.wikidata.length === 1 && l.wikidata[0] === qid)) return ["MusicBrainz label links to a different Wikidata item", l.wikidata.join(",")];
  return null;
}

// Discogs IDs: the MBID is on Wikidata. Returns [reason, detail], "already" or a candidate.
function discogsDirection(l, items) {
  if (items.length > 1) return ["MBID on more than one item", ""];
  const qid = items[0];
  const has = itemDiscogsAnyRank.get(qid) ?? [];
  if (l.discogs.some((d) => has.includes(d))) return "already";
  if (itemToMbids.get(qid).length > 1) return ["item has more than one MusicBrainz label ID", itemToMbids.get(qid).join(",")];
  const p = mbSideProblem(l, qid);
  if (p) return p;
  if (has.length) return ["item already has a different Discogs label ID", has.join(",")];
  if (discogsAnyRank.has(l.discogs[0])) return ["Discogs ID already on another item", discogsAnyRank.get(l.discogs[0]).join(",")];
  return { direction: "discogs", qid, mbid: l.mbid, discogs: l.discogs[0], mbName: l.name };
}

// MusicBrainz IDs: the MBID isn't on Wikidata (any rank), and its Discogs ID is.
function mbDirection(l, items) {
  if (items.length > 1) return ["Discogs ID on more than one item", ""];
  const qid = items[0];
  if (itemMbidAnyRank.has(qid)) return ["item already has a different MusicBrainz label ID", itemMbidAnyRank.get(qid).join(",")];
  if (itemToDiscogs.get(qid).length > 1) return ["item has more than one Discogs label ID", itemToDiscogs.get(qid).join(",")];
  return mbSideProblem(l, qid) ?? { direction: "mb", qid, mbid: l.mbid, discogs: l.discogs[0], mbName: l.name };
}

for (const l of labels) {
  const row = { mbid: l.mbid, mbName: l.name, discogs: l.discogs.join(",") };
  const results = [];
  const mbItems = mbidToItems.get(l.mbid);
  if (mbItems) results.push(["discogs", mbItems, discogsDirection(l, mbItems)]);
  else if (!mbidAnyRank.has(l.mbid)) {
    // With several Discogs links there's no single item to pick, so look for items by any of them
    // and let mbSideProblem reject it.
    const items = [...new Set(l.discogs.flatMap((d) => discogsToItems.get(d) ?? []))];
    if (items.length) results.push(["mb", items, mbDirection(l, items)]);
  }
  for (const [direction, items, res] of results) {
    if (res === "already") alreadyLinked[direction]++;
    else if (Array.isArray(res)) skip(direction, { ...row, qid: items.join(",") }, ...res);
    else candidates.push(res);
  }
}

// An item gets at most one new value. If two MusicBrainz labels lead to the same item, drop both.
const perItem = groupBy(candidates, "qid", (c) => c);
const final = [];
for (const c of candidates) {
  const same = perItem.get(c.qid).filter((o) => o.direction === c.direction);
  if (same.length > 1) skip(c.direction, c, "several MusicBrainz labels lead to this item", same.map((o) => o.mbid).join(","));
  else final.push(c);
}

writeTsv(join(dir, "candidates.tsv"), ["direction", "qid", "mbid", "discogs", "mbName"], final);
writeTsv(join(dir, "match-skipped.tsv"), ["direction", "qid", "mbid", "discogs", "mbName", "reason", "detail"], skipped);
console.error(
  JSON.stringify(
    {
      mbLabels: read,
      mbLabelsWithDiscogs: labels.length,
      unparsedDiscogsLinks: unparsedLinks,
      alreadyLinkedOnWikidata: alreadyLinked.discogs,
      skipped: counts,
      candidates: { discogs: final.filter((c) => c.direction === "discogs").length, mb: final.filter((c) => c.direction === "mb").length },
    },
    null,
    2,
  ),
);
