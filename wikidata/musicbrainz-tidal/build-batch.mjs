// Step 4: check the candidates against live Wikidata and the Tidal names, and write the
// QuickStatements batches.
//
// Usage: CONTACT_EMAIL=you@example.com node build-batch.mjs [dir] [--retrieved YYYY-MM-DD]
//          [--batch-size N] [--limit N]
//   --retrieved   date for the retrieved (P813) qualifier on the reference. Use the date of the
//                 MusicBrainz dump (the name of its folder on data.metabrainz.org). Defaults to today.
//   --batch-size  commands per output file (default 10000).
//   --limit       only use the first N candidates, for a test run.
//
// Reads <dir>/candidates.tsv and <dir>/tidal-artists.tsv. Writes <dir>/tidal-ids-NNN.qs.txt
// (QuickStatements v1) and <dir>/skipped.tsv.
//
// Each statement gets the reference matched by identifier from (P11797): MusicBrainz (Q14005),
// MusicBrainz artist ID (P434) and retrieved (P813).
//
// A candidate is left out when:
//   - Tidal has no artist with the ID, or answers with a different artist ID
//   - live Wikidata shows the item is gone or redirected, now has a Tidal artist ID, or no longer
//     has exactly one MBID (the matched one, not counting deprecated statements)
//   - the Wikidata Query Service (minutes behind live edits, unlike QLever's copy) shows the Tidal ID
//     is now on another item
//   - the item has no en or mul label, or that label doesn't match the Tidal artist's name. The
//     en label is used if there is one, and the mul label otherwise. Both names go through
//     normalize() from ../musicbrainz-discogs/normalize.mjs, and they match if the Levenshtein
//     distance between them is at most 2 and at most 20% of the longer one, the same rule as
//     ../iswc-musicbrainz ("Ultramagnetic MCs" ~ "Ultramagnetic MC's", but not "Hi" ~ "חי").

import { readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";
import { fetchJson, readTsv, writeTsv } from "./common.mjs";
import { normalize } from "../musicbrainz-discogs/normalize.mjs";
import { levenshtein } from "../iswc-musicbrainz/common.mjs";

function namesMatch(a, b) {
  const x = normalize(a);
  const y = normalize(b);
  if (x === y) return true;
  const d = levenshtein(x, y);
  return d <= 2 && d <= 0.2 * Math.max([...x].length, [...y].length);
}

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    retrieved: { type: "string", default: new Date().toISOString().slice(0, 10) },
    "batch-size": { type: "string", default: "10000" },
    limit: { type: "string" },
  },
});
const dir = positionals[0] ?? ".";
if (!/^\d{4}-\d{2}-\d{2}$/.test(opts.retrieved)) throw new Error("--retrieved must be YYYY-MM-DD");
const batchSize = Number(opts["batch-size"]);
if (!Number.isInteger(batchSize) || batchSize < 1) throw new Error("--batch-size must be a positive integer");

const limit = opts.limit === undefined ? Infinity : Number(opts.limit);
if (!(limit === Infinity || (Number.isInteger(limit) && limit > 0))) throw new Error("--limit must be a positive integer");
const candidates = readTsv(join(dir, "candidates.tsv")).slice(0, limit);
const tidal = new Map(readTsv(join(dir, "tidal-artists.tsv")).map((r) => [r.tidal, r]));

const skipped = [];
const counts = {};
const skip = (c, reason, detail = "") => {
  skipped.push({ ...c, reason, detail });
  counts[reason] = (counts[reason] ?? 0) + 1;
};

// 1. Tidal
const remaining = [];
for (const c of candidates) {
  const d = tidal.get(c.tidal);
  if (!d) skip(c, "not looked up on Tidal yet (rerun tidal-names.mjs)");
  else if (d.status !== "ok") skip(c, "no Tidal artist with this ID");
  else if (d.id !== c.tidal) skip(c, "Tidal answers with a different artist ID", d.id);
  else remaining.push({ ...c, tidalName: d.name });
}

// 2. Live Wikidata, since QLever's copy can be a few days old.
const API = "https://www.wikidata.org/w/api.php";
const qids = [...new Set(remaining.map((c) => c.qid))];
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
  if ((i / 50) % 50 === 0) console.error(`fetched ${Math.min(i + 50, qids.length)}/${qids.length}`);
  await sleep(500);
}

// 3. Every Tidal artist ID on Wikidata now, from the Wikidata Query Service, to catch IDs added to
// another item since the QLever snapshot. One query; values that are full URLs count by their ID.
console.error("fetching current Tidal artist IDs from the Wikidata Query Service");
const wdqs = await fetchJson("https://query.wikidata.org/sparql", {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/sparql-results+json" },
  body: new URLSearchParams({ query: "SELECT ?item ?value WHERE { ?item p:P4576/ps:P4576 ?value }" }),
});
const liveTidalToItems = new Map();
for (const b of wdqs.results.bindings) {
  const id = b.value.value.match(/tidal\.com\/(?:browse\/)?artist\/(\d+)/)?.[1] ?? b.value.value;
  const qid = b.item.value.split("/").pop();
  (liveTidalToItems.get(id) ?? liveTidalToItems.set(id, new Set()).get(id)).add(qid);
}
console.error(`${wdqs.results.bindings.length} Tidal artist ID statements on Wikidata`);

const SUMMARY = "/* import Tidal artist ID (P4576) from MusicBrainz */";
const retrieved = `+${opts.retrieved}T00:00:00Z/11`;
const lines = [];
const accepted = [];
for (const c of remaining) {
  const entity = entities[c.qid];
  if (!entity || entity.missing !== undefined) { skip(c, "item missing"); continue; }
  if (entity.id !== c.qid) { skip(c, "item redirected", entity.id); continue; }
  const claims = entity.claims ?? {};
  if (claims.P4576?.length) { skip(c, "item now has a Tidal artist ID", claims.P4576.map((s) => s.mainsnak.datavalue?.value).join(",")); continue; }
  const mbids = new Set((claims.P434 ?? []).filter((s) => s.rank !== "deprecated").map((s) => s.mainsnak.datavalue?.value?.toLowerCase()));
  if (mbids.size !== 1 || !mbids.has(c.mbid)) { skip(c, "item's MBIDs changed", [...mbids].join(",")); continue; }
  const label = entity.labels?.en?.value ?? entity.labels?.mul?.value;
  if (!label) { skip(c, "no en or mul label"); continue; }
  if (!namesMatch(label, c.tidalName)) { skip(c, "name mismatch", `${label} | ${c.tidalName}`); continue; }
  const others = [...(liveTidalToItems.get(c.tidal) ?? [])].filter((q) => q !== c.qid);
  if (others.length) { skip(c, "Tidal ID now on another item", others.join(",")); continue; }
  lines.push(`${c.qid}\tP4576\t"${c.tidal}"\tS11797\tQ14005\tS434\t"${c.mbid}"\tS813\t${retrieved}\t${SUMMARY}`);
  accepted.push({ ...c, wdLabel: label });
}

// 4. Write the batches and reports.
// Remove batches from an earlier run first, so a rebuild with fewer files doesn't leave a stale one.
for (const f of readdirSync(dir)) if (/^tidal-ids-\d{3}\.qs\.txt$/.test(f)) rmSync(join(dir, f));
const files = [];
for (let i = 0; i < lines.length; i += batchSize) {
  const name = `tidal-ids-${String(i / batchSize + 1).padStart(3, "0")}.qs.txt`;
  writeFileSync(join(dir, name), lines.slice(i, i + batchSize).join("\n") + "\n");
  files.push(name);
}
writeTsv(join(dir, "accepted.tsv"), ["qid", "wdLabel", "tidalName", "mbName", "tidal", "mbid"], accepted);
writeTsv(join(dir, "skipped.tsv"), ["qid", "mbid", "tidal", "mbName", "tidalName", "reason", "detail"], skipped);
console.error(JSON.stringify({ candidates: candidates.length, statements: lines.length, files, skipped: counts }, null, 2));
