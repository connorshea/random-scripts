// Step 2: get the title and ISRCs of each candidate recording from the MusicBrainz search API.
//
// Usage: CONTACT_EMAIL=you@example.com node search-recordings.mjs [dir] [--interval-ms 1100]
//   --interval-ms  minimum time between requests (default 1100; MusicBrainz allows one a second).
//   Reads <dir>/candidates.tsv and writes <dir>/mb-recordings.tsv: mbid, title, isrcs
//   (comma-separated). Recordings the search doesn't return get no row.
//
// There's no small dump to use instead: recording.tar.xz only holds standalone recordings (about
// 157,000, which covered 13 of 6,952 candidates on 2026-11-02), and recordings on releases are only
// in the 23 GB release dump. Search takes 100 MBIDs a request (query rid:a OR rid:b …), so ~7,000
// candidates take about 70 requests.
//
// Limits of search compared to a lookup:
//   - it doesn't follow merges, so a merged recording comes back missing, like a deleted one
//   - results don't include URL relationships, so the Wikidata link check in build-batch.mjs has
//     nothing to check
//   - the search index can lag the database slightly

import { join } from "node:path";
import { parseArgs } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";
import { fetchJson, readTsv, writeTsv } from "./common.mjs";

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: { "interval-ms": { type: "string", default: "1100" } },
});
const dir = positionals[0] ?? ".";
const intervalMs = Number(opts["interval-ms"]);
if (!Number.isInteger(intervalMs) || intervalMs < 0) throw new Error("--interval-ms must be a non-negative integer");

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const all = [...new Set(readTsv(join(dir, "candidates.tsv")).map((r) => r.mbid))];
const ids = all.filter((m) => UUID.test(m));
if (ids.length < all.length) console.error(`${all.length - ids.length} MBIDs aren't UUIDs and are left out`);

const rows = [];
for (let i = 0; i < ids.length; i += 100) {
  if (i) await sleep(intervalMs);
  const batch = ids.slice(i, i + 100);
  const params = new URLSearchParams({ query: batch.map((m) => `rid:${m}`).join(" OR "), limit: "100", fmt: "json" });
  const body = await fetchJson(`https://musicbrainz.org/ws/2/recording?${params}`);
  const wanted = new Set(batch);
  for (const r of body.recordings ?? []) {
    if (wanted.has(r.id)) rows.push({ mbid: r.id, title: r.title, isrcs: (r.isrcs ?? []).join(",") });
  }
  if ((i / 100) % 10 === 9 || i + 100 >= ids.length) console.error(`searched ${Math.min(i + 100, ids.length)}/${ids.length}`);
}

writeTsv(join(dir, "mb-recordings.tsv"), ["mbid", "title", "isrcs"], rows);
const withIsrc = rows.filter((r) => r.isrcs).length;
console.error(`${rows.length}/${ids.length} recordings found, ${withIsrc} with at least one ISRC -> mb-recordings.tsv`);
