// Step 3: look up each candidate Deezer artist with the Deezer API to get its name.
//
// Usage: CONTACT_EMAIL=you@example.com node deezer-names.mjs [dir] [--limit N]
//   --limit  only look at the first N candidates, for a test run.
//   Reads <dir>/candidates.tsv and appends to <dir>/deezer-artists.tsv (deezer, status, id, name).
//   status is "ok" or "not found". The file doubles as a cache: IDs already in it are skipped, so
//   the script can be stopped and rerun. Lookups that fail for other reasons aren't recorded, so a
//   rerun retries them.
//
// Uses the public endpoint https://api.deezer.com/artist/<id>, which needs no API key. Requests are
// spread out to at most 9 a second, under Deezer's quota of 50 requests per 5 seconds. If Deezer
// still answers "Quota limit exceeded" (error code 4) the script backs off and retries.
//
// Only numeric IDs are ever sent: given something else, like /artist/abc, Deezer searches by name
// and returns whatever artist it finds.

import { appendFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";
import { fetchJson, readTsv, tsvLine } from "./common.mjs";

const { values: opts, positionals } = parseArgs({ allowPositionals: true, options: { limit: { type: "string" } } });
const dir = positionals[0] ?? ".";
const limit = opts.limit === undefined ? Infinity : Number(opts.limit);
if (!(limit === Infinity || (Number.isInteger(limit) && limit > 0))) throw new Error("--limit must be a positive integer");
const cachePath = join(dir, "deezer-artists.tsv");
const COLS = ["deezer", "status", "id", "name"];

const done = new Set(existsSync(cachePath) ? readTsv(cachePath).map((r) => r.deezer) : []);
if (!existsSync(cachePath)) appendFileSync(cachePath, COLS.join("\t") + "\n");
const todo = [...new Set(readTsv(join(dir, "candidates.tsv")).slice(0, limit).map((r) => r.deezer))].filter((id) => !done.has(id));
console.error(`${done.size} already looked up, ${todo.length} to go`);

// Rate limiter shared by the workers: one request every INTERVAL_MS at most.
const REQUESTS_PER_SECOND = 9;
const INTERVAL_MS = 1000 / REQUESTS_PER_SECOND;
let nextSlot = 0;
async function slot() {
  const now = Date.now();
  const at = Math.max(now, nextSlot);
  nextSlot = at + INTERVAL_MS;
  if (at > now) await sleep(at - now);
}

async function lookup(id) {
  if (!/^\d+$/.test(id)) throw new Error(`not a numeric Deezer ID: ${id}`);
  for (let attempt = 0; ; attempt++) {
    await slot();
    const body = await fetchJson(`https://api.deezer.com/artist/${id}`);
    if (!body.error) return { deezer: id, status: "ok", id: String(body.id), name: body.name };
    if (body.error.code === 800) return { deezer: id, status: "not found", id: "", name: "" };
    if (body.error.code === 4 && attempt < 6) {
      const wait = 10 * 2 ** attempt;
      console.error(`Deezer quota exceeded, waiting ${wait}s`);
      await sleep(wait * 1000);
      continue;
    }
    throw new Error(`Deezer error for ${id}: ${JSON.stringify(body.error)}`);
  }
}

let i = 0;
let ok = 0;
let notFound = 0;
let failed = 0;
async function worker() {
  while (i < todo.length) {
    const id = todo[i++];
    try {
      const row = await lookup(id);
      appendFileSync(cachePath, tsvLine(COLS, row) + "\n");
      if (row.status === "ok") ok++;
      else notFound++;
    } catch (e) {
      failed++;
      console.error(e.message);
    }
    const n = ok + notFound + failed;
    if (n % 1000 === 0) console.error(`${n}/${todo.length}`);
  }
}
await Promise.all(Array.from({ length: 4 }, worker));
console.error(JSON.stringify({ lookedUp: ok + notFound, ok, notFound, failed }, null, 2));
if (failed) console.error("Some lookups failed and weren't recorded. Rerun to retry them.");
