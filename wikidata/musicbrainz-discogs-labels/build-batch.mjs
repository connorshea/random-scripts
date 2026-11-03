// Step 4: check the candidates against live Wikidata and the names, and write the QuickStatements
// batches.
//
// Usage: CONTACT_EMAIL=you@example.com node build-batch.mjs [dir] [--retrieved YYYY-MM-DD]
//          [--batch-size N]
//   --retrieved   date for the retrieved (P813) qualifier on the reference. Use the date of the
//                 MusicBrainz dump (the name of its folder on data.metabrainz.org). Defaults to today.
//   --batch-size  commands per output file (default 10000).
//
// Reads <dir>/candidates.tsv and <dir>/discogs-labels.tsv. Writes <dir>/discogs-label-ids-NNN.qs.txt
// (Discogs label ID, P1955), <dir>/mb-label-ids-NNN.qs.txt (MusicBrainz label ID, P966),
// <dir>/accepted.tsv and <dir>/skipped.tsv. Batch files from an earlier run are deleted first.
//
// References use matched by identifier from (P11797) with the ID the match went through:
//   P1955: MusicBrainz (Q14005), MusicBrainz label ID (P966), retrieved (P813)
//   P966:  Discogs (Q504063), Discogs label ID (P1955), retrieved (P813)
//
// A candidate is left out when:
//   - live Wikidata shows the item is gone or redirected, or it's an instance of human (Q5)
//   - the item now has the property being added (any rank), or no longer has exactly one
//     non-deprecated value of the property it was matched through (the matched one)
//   - the item has no en or mul label, or that label doesn't match the name on the side being
//     added: the Discogs name (without its " (N)" suffix) for P1955, the MusicBrainz name for P966.
//     Names go through normalize() from ../musicbrainz-discogs/normalize.mjs, lose a trailing
//     "Records", "Recordings", "Label(s)" or "Music" and a company suffix like "Ltd" or "Inc", and
//     match if the Levenshtein distance is at most 2 and at most 20% of the longer name.
//   - the Discogs ID isn't in the Discogs dump (deleted or merged on Discogs), in either direction

import { readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";
import { fetchJson, readTsv, writeTsv } from "./common.mjs";
import { levenshtein } from "../iswc-musicbrainz/common.mjs";
import { normalize, stripDiscogsSuffix } from "../musicbrainz-discogs/normalize.mjs";

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    retrieved: { type: "string", default: new Date().toISOString().slice(0, 10) },
    "batch-size": { type: "string", default: "10000" },
  },
});
const dir = positionals[0] ?? ".";
if (!/^\d{4}-\d{2}-\d{2}$/.test(opts.retrieved)) throw new Error("--retrieved must be YYYY-MM-DD");
const batchSize = Number(opts["batch-size"]);
if (!Number.isInteger(batchSize) || batchSize < 1) throw new Error("--batch-size must be a positive integer");

// Label names often differ only by a generic word at the end ("Avatar Records" vs "Avatar",
// "Wichita Recordings" vs "Wichita"), so those are dropped before comparing, along with a company
// suffix after them. A name that's nothing but those words is kept as it is.
const GENERIC_END = / (?:records|recordings|recording|label|labels|music)(?: (?:ltd|limited|inc|llc|gmbh))?$|(?: (?:ltd|limited|inc|llc|gmbh))$/;
function labelName(s) {
  const n = normalize(s);
  let stripped = n;
  // Repeat, so "Naked Music Recordings" and "Naked Music" both end up as "naked".
  for (let prev; prev !== stripped; ) [prev, stripped] = [stripped, stripped.replace(GENERIC_END, "").trim()];
  return stripped || n;
}

function namesMatch(a, b) {
  const x = labelName(a);
  const y = labelName(b);
  if (x === y) return true;
  const d = levenshtein(x, y);
  return d <= 2 && d <= 0.2 * Math.max([...x].length, [...y].length);
}
const discogsIdOf = (v) => v.match(/discogs\.com\/(?:[a-z]{2}\/)?label\/(\d+)/)?.[1] ?? v;

const DIRECTIONS = {
  discogs: { add: "P1955", via: "P966", prefix: "discogs-label-ids", ref: (c) => `S11797\tQ14005\tS966\t"${c.mbid}"`, summary: "/* import Discogs label ID (P1955) from MusicBrainz */" },
  mb: { add: "P966", via: "P1955", prefix: "mb-label-ids", ref: (c) => `S11797\tQ504063\tS1955\t"${c.discogs}"`, summary: "/* import MusicBrainz label ID (P966) matched by Discogs label ID */" },
};

const candidates = readTsv(join(dir, "candidates.tsv"));
const discogsNames = new Map(readTsv(join(dir, "discogs-labels.tsv")).map((r) => [r.discogs, r.name]));

const skipped = [];
const counts = { discogs: {}, mb: {} };
const skip = (c, reason, detail = "") => {
  skipped.push({ ...c, reason, detail });
  counts[c.direction][reason] = (counts[c.direction][reason] ?? 0) + 1;
};

// Live Wikidata, since QLever's copy can be behind.
const API = "https://www.wikidata.org/w/api.php";
const qids = [...new Set(candidates.map((c) => c.qid))];
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

const retrieved = `+${opts.retrieved}T00:00:00Z/11`;
const lines = { discogs: [], mb: [] };
const accepted = [];
for (const c of candidates) {
  const d = DIRECTIONS[c.direction];
  const entity = entities[c.qid];
  if (!entity || entity.missing !== undefined) { skip(c, "item missing"); continue; }
  if (entity.id !== c.qid) { skip(c, "item redirected", entity.id); continue; }
  const claims = entity.claims ?? {};
  if (claims[d.add]?.length) { skip(c, `item now has ${d.add}`); continue; }
  const via = (claims[d.via] ?? []).filter((s) => s.rank !== "deprecated").map((s) => s.mainsnak.datavalue?.value ?? s.mainsnak.snaktype);
  const expected = c.direction === "discogs" ? c.mbid : c.discogs;
  const norm = (v) => (c.direction === "discogs" ? String(v).toLowerCase() : discogsIdOf(String(v)));
  if (via.length !== 1 || norm(via[0]) !== expected) { skip(c, `item no longer has exactly the matched ${d.via}`, via.join(",")); continue; }
  // A label ID on a person's item is usually their imprint ("Doja Cat Music") conflated with them,
  // so don't add to it.
  const p31 = (claims.P31 ?? []).filter((s) => s.rank !== "deprecated").map((s) => s.mainsnak.datavalue?.value?.id);
  if (p31.includes("Q5")) { skip(c, "item is a human"); continue; }
  const label = entity.labels?.en?.value ?? entity.labels?.mul?.value;
  if (!label) { skip(c, "no en or mul label"); continue; }
  // In both directions: a Discogs ID that's gone from Discogs (deleted or merged) is a stale link.
  if (!discogsNames.has(c.discogs)) { skip(c, "Discogs ID not in the Discogs dump"); continue; }
  const name = c.direction === "discogs" ? stripDiscogsSuffix(discogsNames.get(c.discogs)) : c.mbName;
  if (!namesMatch(label, name)) { skip(c, "name mismatch", `${label} | ${name}`); continue; }
  const value = c.direction === "discogs" ? c.discogs : c.mbid;
  lines[c.direction].push(`${c.qid}\t${d.add}\t"${value}"\t${d.ref(c)}\tS813\t${retrieved}\t${d.summary}`);
  accepted.push({ ...c, wdLabel: label, discogsName: discogsNames.get(c.discogs) ?? "" });
}

for (const f of readdirSync(dir)) if (/^(discogs|mb)-label-ids-\d{3}\.qs\.txt$/.test(f)) rmSync(join(dir, f));
const files = [];
for (const [direction, ls] of Object.entries(lines)) {
  for (let i = 0; i < ls.length; i += batchSize) {
    const name = `${DIRECTIONS[direction].prefix}-${String(i / batchSize + 1).padStart(3, "0")}.qs.txt`;
    writeFileSync(join(dir, name), ls.slice(i, i + batchSize).join("\n") + "\n");
    files.push(name);
  }
}
writeTsv(join(dir, "accepted.tsv"), ["direction", "qid", "wdLabel", "mbName", "discogsName", "mbid", "discogs"], accepted);
writeTsv(join(dir, "skipped.tsv"), ["direction", "qid", "mbid", "discogs", "mbName", "reason", "detail"], skipped);
console.error(
  JSON.stringify(
    {
      candidates: { discogs: candidates.filter((c) => c.direction === "discogs").length, mb: candidates.filter((c) => c.direction === "mb").length },
      statements: { P1955: lines.discogs.length, P966: lines.mb.length },
      files,
      skipped: counts,
    },
    null,
    2,
  ),
);
