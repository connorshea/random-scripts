// Step 3: decide which ISWCs to add, check the items against live Wikidata, and write the
// QuickStatements batches.
//
// Usage: CONTACT_EMAIL=you@example.com node build-batch.mjs [dir] [--retrieved YYYY-MM-DD]
//          [--max-iswcs N] [--batch-size N]
//   --retrieved   date for the retrieved (P813) qualifier on the reference. Use the date of the
//                 MusicBrainz dump (the name of its folder on data.metabrainz.org). Defaults to today.
//   --max-iswcs   skip MusicBrainz works with more ISWCs than this (default 1). A work with several
//                 ISWCs usually has extra registrations from other societies or publishers, or for
//                 arrangements and translations, which are better reviewed by hand.
//   --batch-size  commands per output file (default 10000).
//
// Reads <dir>/candidates.tsv, <dir>/existing-iswcs.tsv and <dir>/mb-works.tsv. Writes
// <dir>/iswc-import-NNN.qs.txt (QuickStatements v1, one ISWC statement per line) and
// <dir>/skipped.tsv.
//
// Each statement gets the reference stated in (P248) MusicBrainz (Q14005), MusicBrainz work ID
// (P435) and retrieved (P813).
//
// ISWCs are left out when:
//   - the item has more than one MusicBrainz work ID (P435), in QLever's data or on live Wikidata
//   - the item's MBID isn't in the dump (the work was merged or deleted on MusicBrainz)
//   - the MusicBrainz work links to a different Wikidata item
//   - the MusicBrainz work has more than --max-iswcs ISWCs
//   - the ISWC is malformed or its check digit is wrong
//   - the ISWC is already on another Wikidata item, or would be added to more than one item
//   - live Wikidata shows the item is gone or redirected, now has an ISWC, no longer has the MBID,
//     or has an instance of (P31) other than musical work/composition (Q105543609)
//   - the item's English label (or its mul label, if it has no English one) doesn't match the
//     MusicBrainz work's title. Both are run through normalize() from
//     ../musicbrainz-discogs/normalize.mjs, and they match if the Levenshtein distance between them
//     is at most 2 and at most 20% of the longer one ("Rockin'" ~ "Rocking", "USA" ~ "U.S.A.",
//     "Marshmallow World" ~ "A Marshmallow World", but not "Hi" ~ "חי").

import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";
import { fetchJson, readTsv, writeTsv, canonicalizeIswc, iswcCheckDigitOk, levenshtein } from "./common.mjs";
import { normalize } from "../musicbrainz-discogs/normalize.mjs";

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    retrieved: { type: "string", default: new Date().toISOString().slice(0, 10) },
    "max-iswcs": { type: "string", default: "1" },
    "batch-size": { type: "string", default: "10000" },
  },
});
const dir = positionals[0] ?? ".";
if (!/^\d{4}-\d{2}-\d{2}$/.test(opts.retrieved)) throw new Error("--retrieved must be YYYY-MM-DD");
const maxIswcs = Number(opts["max-iswcs"]);
const batchSize = Number(opts["batch-size"]);
if (!Number.isInteger(maxIswcs) || maxIswcs < 1) throw new Error("--max-iswcs must be a positive integer");
if (!Number.isInteger(batchSize) || batchSize < 1) throw new Error("--batch-size must be a positive integer");

function namesMatch(a, b) {
  const x = normalize(a);
  const y = normalize(b);
  if (x === y) return true;
  const d = levenshtein(x, y);
  return d <= 2 && d <= 0.2 * Math.max([...x].length, [...y].length);
}

const CANONICAL = /^T-[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]$/;

// qid -> [mbid]
const itemMbids = new Map();
for (const { qid, mbid } of readTsv(join(dir, "candidates.tsv"))) {
  (itemMbids.get(qid) ?? itemMbids.set(qid, []).get(qid)).push(mbid);
}
// iswc -> Set(qid)
const existing = new Map();
for (const { iswc, qid } of readTsv(join(dir, "existing-iswcs.tsv"))) {
  (existing.get(iswc) ?? existing.set(iswc, new Set()).get(iswc)).add(qid);
}
const works = new Map(readTsv(join(dir, "mb-works.tsv")).map((w) => [w.mbid, w]));

const skipped = [];
const counts = {};
const skip = (row) => {
  skipped.push(row);
  counts[row.reason] = (counts[row.reason] ?? 0) + 1;
};
let noIswc = 0;

// 1. Proposals from the dump: qid -> Map(iswc -> mbid)
const proposals = new Map();
for (const [qid, mbids] of itemMbids) {
  if (mbids.length > 1) {
    skip({ qid, mbid: mbids.join(","), reason: "item has more than one MusicBrainz work ID" });
    continue;
  }
  const found = mbids.map((m) => works.get(m)).filter(Boolean);
  for (const m of mbids) {
    if (!works.has(m)) skip({ qid, mbid: m, reason: "MBID not in dump (merged or deleted on MusicBrainz)" });
  }
  if (found.length === 0) continue;
  if (found.every((w) => !w.iswcs)) {
    noIswc++;
    continue;
  }

  const mismatched = found.filter((w) => w.wikidata && !w.wikidata.split(",").includes(qid));
  if (mismatched.length) {
    for (const w of mismatched) skip({ qid, mbid: w.mbid, detail: w.wikidata, reason: "MusicBrainz work links to a different Wikidata item" });
    continue;
  }

  const iswcs = new Map();
  for (const w of found) {
    if (!w.iswcs) continue;
    const list = w.iswcs.split(",");
    if (list.length > maxIswcs) {
      skip({ qid, mbid: w.mbid, detail: w.iswcs, reason: `MusicBrainz work has more than ${maxIswcs} ISWC${maxIswcs === 1 ? "" : "s"}` });
      continue;
    }
    for (const raw of list) {
      const iswc = CANONICAL.test(raw) ? raw : canonicalizeIswc(raw);
      if (!iswc || !iswcCheckDigitOk(iswc)) {
        skip({ qid, mbid: w.mbid, iswc: raw, reason: "malformed ISWC or wrong check digit" });
        continue;
      }
      if (!iswcs.has(iswc)) iswcs.set(iswc, w.mbid);
    }
  }
  if (iswcs.size) proposals.set(qid, iswcs);
}

// 2. Uniqueness: don't add an ISWC that's on another item already, or that would go on two items.
const proposedFor = new Map();
for (const [qid, iswcs] of proposals) {
  for (const iswc of iswcs.keys()) (proposedFor.get(iswc) ?? proposedFor.set(iswc, []).get(iswc)).push(qid);
}
for (const [qid, iswcs] of proposals) {
  for (const [iswc, mbid] of iswcs) {
    const others = [...(existing.get(iswc) ?? [])].filter((q) => q !== qid);
    if (others.length) {
      skip({ qid, mbid, iswc, detail: others.join(","), reason: "ISWC already on another Wikidata item" });
      iswcs.delete(iswc);
    } else if (proposedFor.get(iswc).length > 1) {
      skip({ qid, mbid, iswc, detail: proposedFor.get(iswc).filter((q) => q !== qid).join(","), reason: "ISWC would be added to more than one item" });
      iswcs.delete(iswc);
    }
  }
  if (!iswcs.size) proposals.delete(qid);
}

// 3. Check the remaining items against live Wikidata, since QLever's copy can be a few days old.
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

const SUMMARY = "/* import ISWC (P1827) from MusicBrainz */";
const retrieved = `+${opts.retrieved}T00:00:00Z/11`;
const lines = [];
const added = new Set();
for (const qid of qids) {
  const entity = entities[qid];
  const itemSkip = (reason) => skip({ qid, reason });
  if (!entity || entity.missing !== undefined) { itemSkip("item missing"); continue; }
  if (entity.id !== qid) { itemSkip(`item redirected`); continue; }
  const claims = entity.claims ?? {};
  if (claims.P1827?.length) { itemSkip("item now has an ISWC"); continue; }
  // Every non-deprecated instance of (P31) has to be musical work/composition. A novalue or
  // somevalue P31 counts as another type.
  const p31 = (claims.P31 ?? []).filter((s) => s.rank !== "deprecated").map((s) => s.mainsnak.datavalue?.value?.id ?? s.mainsnak.snaktype);
  if (p31.length === 0 || p31.some((t) => t !== "Q105543609")) {
    skip({ qid, detail: p31.join(","), reason: "instance of something other than musical work/composition" });
    continue;
  }
  const label = entity.labels?.en?.value ?? entity.labels?.mul?.value;
  if (!label) { itemSkip("no en or mul label"); continue; }
  const liveMbids = new Set(
    (claims.P435 ?? []).filter((s) => s.rank !== "deprecated").map((s) => s.mainsnak.datavalue?.value?.toLowerCase()),
  );
  if (liveMbids.size > 1) {
    skip({ qid, mbid: [...liveMbids].join(","), reason: "item has more than one MusicBrainz work ID" });
    continue;
  }
  for (const [iswc, mbid] of proposals.get(qid)) {
    if (!liveMbids.has(mbid)) {
      skip({ qid, mbid, iswc, reason: "item no longer has the MBID" });
      continue;
    }
    const title = works.get(mbid).title;
    if (!namesMatch(label, title)) {
      skip({ qid, mbid, iswc, detail: `${label} | ${title}`, reason: "name mismatch" });
      continue;
    }
    lines.push(`${qid}\tP1827\t"${iswc}"\tS248\tQ14005\tS435\t"${mbid}"\tS813\t${retrieved}\t${SUMMARY}`);
    added.add(qid);
  }
}

// 4. Write the batches and the skip report.
const files = [];
for (let i = 0; i < lines.length; i += batchSize) {
  const name = `iswc-import-${String(i / batchSize + 1).padStart(3, "0")}.qs.txt`;
  writeFileSync(join(dir, name), lines.slice(i, i + batchSize).join("\n") + "\n");
  files.push(name);
}
writeTsv(join(dir, "skipped.tsv"), ["qid", "mbid", "iswc", "reason", "detail"], skipped);

console.error(
  JSON.stringify(
    {
      candidateItems: itemMbids.size,
      itemsWithoutIswcOnMusicBrainz: noIswc,
      statements: lines.length,
      itemsEdited: added.size,
      files,
      skipped: counts,
    },
    null,
    2,
  ),
);
