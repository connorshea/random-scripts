// Step 3: decide which ISRCs to add, check the items against live Wikidata, and write the
// QuickStatements batches.
//
// Usage: CONTACT_EMAIL=you@example.com node build-batch.mjs [dir] [--retrieved YYYY-MM-DD]
//          [--max-isrcs N] [--batch-size N]
//   --retrieved   date for the retrieved (P813) qualifier on the reference. Use the date of the
//                 MusicBrainz dump (the name of its folder on data.metabrainz.org). Defaults to today.
//   --max-isrcs   skip MusicBrainz recordings with more ISRCs than this (default 1). A recording
//                 often has several ISRCs from reissues on different labels, and they're all
//                 valid, but a long list is more likely to include one attached to the wrong
//                 recording.
//   --batch-size  commands per output file (default 10000).
//
// Reads <dir>/candidates.tsv, <dir>/existing-isrcs.tsv and <dir>/mb-recordings.tsv. Writes
// <dir>/isrc-import-NNN.qs.txt (QuickStatements v1, one ISRC statement per line) and
// <dir>/skipped.tsv. Batch files from an earlier run are deleted first.
//
// Each statement gets the reference stated in (P248) MusicBrainz (Q14005), MusicBrainz recording
// ID (P4404) and retrieved (P813).
//
// ISRCs are left out when:
//   - the item has more than one MusicBrainz recording ID (P4404), in QLever's data or on live
//     Wikidata
//   - MusicBrainz search doesn't return the MBID (the recording was merged or deleted)
//   - the MusicBrainz recording links to a different Wikidata item
//   - the MusicBrainz recording has more than --max-isrcs ISRCs
//   - the ISRC is malformed
//   - the ISRC is already on another Wikidata item, or would be added to more than one item
//   - live Wikidata shows the item is gone or redirected, now has an ISRC, MusicBrainz work ID or
//     ISWC, no longer has the MBID, or has an instance of (P31) that isn't a track type
//   - the item's English label (or its mul label, if it has no English one) doesn't match the
//     MusicBrainz recording's title, using the same rule as ../iswc-musicbrainz: normalize() from
//     ../musicbrainz-discogs/normalize.mjs plus a Levenshtein distance of at most 2 and at most
//     20% of the longer name.

import { readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";
import { fetchJson, readTsv, writeTsv, canonicalizeIsrc, TRACK_TYPES } from "./common.mjs";
import { levenshtein } from "../iswc-musicbrainz/common.mjs";
import { normalize } from "../musicbrainz-discogs/normalize.mjs";

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    retrieved: { type: "string", default: new Date().toISOString().slice(0, 10) },
    "max-isrcs": { type: "string", default: "1" },
    "batch-size": { type: "string", default: "10000" },
  },
});
const dir = positionals[0] ?? ".";
if (!/^\d{4}-\d{2}-\d{2}$/.test(opts.retrieved)) throw new Error("--retrieved must be YYYY-MM-DD");
const maxIsrcs = Number(opts["max-isrcs"]);
const batchSize = Number(opts["batch-size"]);
if (!Number.isInteger(maxIsrcs) || maxIsrcs < 1) throw new Error("--max-isrcs must be a positive integer");
if (!Number.isInteger(batchSize) || batchSize < 1) throw new Error("--batch-size must be a positive integer");

function namesMatch(a, b) {
  const x = normalize(a);
  const y = normalize(b);
  if (x === y) return true;
  const d = levenshtein(x, y);
  return d <= 2 && d <= 0.2 * Math.max([...x].length, [...y].length);
}

// qid -> [mbid]
const itemMbids = new Map();
for (const { qid, mbid } of readTsv(join(dir, "candidates.tsv"))) {
  (itemMbids.get(qid) ?? itemMbids.set(qid, []).get(qid)).push(mbid);
}
// isrc -> Set(qid)
const existing = new Map();
for (const { isrc, qid } of readTsv(join(dir, "existing-isrcs.tsv"))) {
  (existing.get(isrc) ?? existing.set(isrc, new Set()).get(isrc)).add(qid);
}
const recordings = new Map(readTsv(join(dir, "mb-recordings.tsv")).map((r) => [r.mbid, r]));

const skipped = [];
const counts = {};
const skip = (row) => {
  skipped.push(row);
  counts[row.reason] = (counts[row.reason] ?? 0) + 1;
};
let noIsrc = 0;

// 1. Proposals from MusicBrainz: qid -> { mbid, isrcs: [isrc] }
const proposals = new Map();
for (const [qid, mbids] of itemMbids) {
  if (mbids.length > 1) {
    skip({ qid, mbid: mbids.join(","), reason: "item has more than one MusicBrainz recording ID" });
    continue;
  }
  const [mbid] = mbids;
  const r = recordings.get(mbid);
  if (!r) { skip({ qid, mbid, reason: "MBID not found by MusicBrainz search (merged or deleted)" }); continue; }
  if (!r.isrcs) { noIsrc++; continue; }
  if (r.wikidata && !r.wikidata.split(",").includes(qid)) {
    skip({ qid, mbid, detail: r.wikidata, reason: "MusicBrainz recording links to a different Wikidata item" });
    continue;
  }
  const list = r.isrcs.split(",");
  if (list.length > maxIsrcs) {
    skip({ qid, mbid, detail: r.isrcs, reason: `MusicBrainz recording has more than ${maxIsrcs} ISRC${maxIsrcs === 1 ? "" : "s"}` });
    continue;
  }
  const isrcs = new Set();
  for (const raw of list) {
    const isrc = canonicalizeIsrc(raw);
    if (!isrc) skip({ qid, mbid, isrc: raw, reason: "malformed ISRC" });
    else isrcs.add(isrc);
  }
  if (isrcs.size) proposals.set(qid, { mbid, isrcs });
}

// 2. Uniqueness (P1243 has a distinct-values constraint): don't add an ISRC that's on another item
// already, or that would go on two items.
const proposedFor = new Map();
for (const [qid, { isrcs }] of proposals) {
  for (const isrc of isrcs) (proposedFor.get(isrc) ?? proposedFor.set(isrc, []).get(isrc)).push(qid);
}
for (const [qid, { mbid, isrcs }] of proposals) {
  for (const isrc of isrcs) {
    const others = [...(existing.get(isrc) ?? [])].filter((q) => q !== qid);
    if (others.length) {
      skip({ qid, mbid, isrc, detail: others.join(","), reason: "ISRC already on another Wikidata item" });
      isrcs.delete(isrc);
    } else if (proposedFor.get(isrc).length > 1) {
      skip({ qid, mbid, isrc, detail: proposedFor.get(isrc).filter((q) => q !== qid).join(","), reason: "ISRC would be added to more than one item" });
      isrcs.delete(isrc);
    }
  }
  if (!isrcs.size) proposals.delete(qid);
}

// 3. Check the remaining items against live Wikidata, since QLever's copy can be behind.
const API = "https://www.wikidata.org/w/api.php";
const qids = [...proposals.keys()];
console.error(`checking ${qids.length} items against live Wikidata`);
const entities = {};
for (let i = 0; i < qids.length; i += 50) {
  const params = new URLSearchParams({
    action: "wbgetentities",
    ids: qids.slice(i, i + 50).join("|"),
    props: "claims|labels",
    languages: "en|mul",
    format: "json",
    maxlag: "5",
  });
  let body = await fetchJson(`${API}?${params}`);
  while (body.error?.code === "maxlag") {
    console.error("maxlag, waiting 10s");
    await sleep(10_000);
    body = await fetchJson(`${API}?${params}`);
  }
  if (body.error) throw new Error(JSON.stringify(body.error));
  Object.assign(entities, body.entities);
  if ((i / 50) % 20 === 0) console.error(`fetched ${Math.min(i + 50, qids.length)}/${qids.length}`);
  await sleep(500);
}

const SUMMARY = "/* import ISRC (P1243) from MusicBrainz */";
const retrieved = `+${opts.retrieved}T00:00:00Z/11`;
const lines = [];
const added = new Set();
for (const qid of qids) {
  const { mbid, isrcs } = proposals.get(qid);
  const entity = entities[qid];
  const itemSkip = (reason, detail = "") => skip({ qid, mbid, reason, detail });
  if (!entity || entity.missing !== undefined) { itemSkip("item missing"); continue; }
  if (entity.id !== qid) { itemSkip("item redirected", entity.id); continue; }
  const claims = entity.claims ?? {};
  if (claims.P1243?.length) { itemSkip("item now has an ISRC"); continue; }
  if (claims.P435?.length || claims.P1827?.length) { itemSkip("item now has a MusicBrainz work ID or ISWC"); continue; }
  // Every non-deprecated instance of (P31) has to be a track type. A novalue or somevalue P31
  // counts as another type.
  const p31 = (claims.P31 ?? []).filter((s) => s.rank !== "deprecated").map((s) => s.mainsnak.datavalue?.value?.id ?? s.mainsnak.snaktype);
  if (p31.length === 0 || p31.some((t) => !TRACK_TYPES.includes(t))) {
    itemSkip("instance of something other than a track type", p31.join(","));
    continue;
  }
  const liveMbids = new Set(
    (claims.P4404 ?? []).filter((s) => s.rank !== "deprecated").map((s) => s.mainsnak.datavalue?.value?.toLowerCase()),
  );
  if (liveMbids.size > 1) { skip({ qid, mbid: [...liveMbids].join(","), reason: "item has more than one MusicBrainz recording ID" }); continue; }
  if (!liveMbids.has(mbid)) { itemSkip("item no longer has the MBID"); continue; }
  const label = entity.labels?.en?.value ?? entity.labels?.mul?.value;
  if (!label) { itemSkip("no en or mul label"); continue; }
  const title = recordings.get(mbid).title;
  if (!namesMatch(label, title)) { itemSkip("name mismatch", `${label} | ${title}`); continue; }
  for (const isrc of isrcs) {
    lines.push(`${qid}\tP1243\t"${isrc}"\tS248\tQ14005\tS4404\t"${mbid}"\tS813\t${retrieved}\t${SUMMARY}`);
  }
  added.add(qid);
}

// 4. Write the batches and the skip report.
for (const f of readdirSync(dir)) if (/^isrc-import-\d{3}\.qs\.txt$/.test(f)) rmSync(join(dir, f));
const files = [];
for (let i = 0; i < lines.length; i += batchSize) {
  const name = `isrc-import-${String(i / batchSize + 1).padStart(3, "0")}.qs.txt`;
  writeFileSync(join(dir, name), lines.slice(i, i + batchSize).join("\n") + "\n");
  files.push(name);
}
writeTsv(join(dir, "skipped.tsv"), ["qid", "mbid", "isrc", "reason", "detail"], skipped);

console.error(
  JSON.stringify(
    {
      candidateItems: itemMbids.size,
      itemsWithoutIsrcOnMusicBrainz: noIsrc,
      statements: lines.length,
      itemsEdited: added.size,
      files,
      skipped: counts,
    },
    null,
    2,
  ),
);
