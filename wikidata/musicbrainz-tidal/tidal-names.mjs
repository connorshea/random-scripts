// Step 3: look up each candidate Tidal artist with the official TIDAL API to get its name.
//
// Usage: TIDAL_CLIENT_ID=... TIDAL_CLIENT_SECRET=... CONTACT_EMAIL=you@example.com \
//          node tidal-names.mjs [dir] [--limit N] [--country US] [--interval-ms 1000]
//   --limit        only look at the first N candidates, for a test run.
//   --country      countryCode to send (default US).
//   --interval-ms  minimum time between API requests (default 1000).
//   Reads <dir>/candidates.tsv and appends to <dir>/tidal-artists.tsv (tidal, status, id, name).
//   status is "ok" or "not found". The file doubles as a cache: IDs already in it are skipped, so
//   the script can be stopped and rerun. Lookups that fail for other reasons aren't recorded, so a
//   rerun retries them.
//
// Auth is the client-credentials flow: the app's client ID and secret go to
// https://auth.tidal.com/v1/oauth2/token for a bearer token, which is renewed when it expires or
// the API answers 401.
//
// Artists are fetched 20 at a time (the API's maximum) with
// GET https://openapi.tidal.com/v2/artists?filter[id]=1&filter[id]=2&... An ID missing from the
// response is recorded as "not found" (checked: the API leaves unknown IDs out). If a whole batch
// answers 404 or 400, its IDs are looked up one by one with GET /v2/artists/<id>, so one bad ID
// doesn't sink the other 19. TIDAL doesn't publish rate limits, so requests go out one at a
// time with --interval-ms between them, and a 429 backs off (Retry-After if given, else 30 s,
// doubling).

import { appendFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";
import { readTsv, tsvLine, userAgent } from "./common.mjs";

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    limit: { type: "string" },
    country: { type: "string", default: "US" },
    "interval-ms": { type: "string", default: "1000" },
  },
});
const dir = positionals[0] ?? ".";
const limit = opts.limit === undefined ? Infinity : Number(opts.limit);
if (!(limit === Infinity || (Number.isInteger(limit) && limit > 0))) throw new Error("--limit must be a positive integer");
if (!/^[A-Z]{2}$/.test(opts.country)) throw new Error("--country must be a two-letter country code like US");
const intervalMs = Number(opts["interval-ms"]);
if (!Number.isInteger(intervalMs) || intervalMs < 0) throw new Error("--interval-ms must be a non-negative integer");

const clientId = process.env.TIDAL_CLIENT_ID;
const clientSecret = process.env.TIDAL_CLIENT_SECRET;
if (!clientId || !clientSecret) {
  console.error("Set TIDAL_CLIENT_ID and TIDAL_CLIENT_SECRET to the TIDAL app's client credentials.");
  process.exit(1);
}

const cachePath = join(dir, "tidal-artists.tsv");
const COLS = ["tidal", "status", "id", "name"];
const done = new Set(existsSync(cachePath) ? readTsv(cachePath).map((r) => r.tidal) : []);
if (!existsSync(cachePath)) appendFileSync(cachePath, COLS.join("\t") + "\n");
const todo = [...new Set(readTsv(join(dir, "candidates.tsv")).slice(0, limit).map((r) => r.tidal))].filter((id) => !done.has(id));
console.error(`${done.size} already looked up, ${todo.length} to go`);

// Token
let token = null;
let tokenExpires = 0;
async function getToken(force = false) {
  if (!force && token && Date.now() < tokenExpires - 60_000) return token;
  const res = await fetch("https://auth.tidal.com/v1/oauth2/token", {
    method: "POST",
    headers: {
      "User-Agent": userAgent(),
      Authorization: `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString("base64")}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ grant_type: "client_credentials" }),
  });
  if (!res.ok) throw new Error(`token request failed: ${res.status} ${(await res.text()).slice(0, 500)}`);
  const body = await res.json();
  token = body.access_token;
  tokenExpires = Date.now() + (Number(body.expires_in) || 3600) * 1000;
  return token;
}

// One request every intervalMs at most.
let nextSlot = 0;
async function slot() {
  const now = Date.now();
  const at = Math.max(now, nextSlot);
  nextSlot = at + intervalMs;
  if (at > now) await sleep(at - now);
}

// GET a path on the API. Returns { status, body } for 200, 404 and 400 (body is the error text for
// 400). 401 renews the token, 429 and 5xx back off, and anything else throws.
async function api(path) {
  for (let attempt = 0, renewed = false; ; attempt++) {
    await slot();
    const res = await fetch(`https://openapi.tidal.com/v2${path}`, {
      headers: { "User-Agent": userAgent(), Accept: "application/vnd.api+json", Authorization: `Bearer ${await getToken()}` },
    });
    if (res.status === 200) return { status: 200, body: await res.json() };
    if (res.status === 404) return { status: 404, body: null };
    if (res.status === 400) return { status: 400, body: (await res.text()).slice(0, 500) };
    if (res.status === 401 && !renewed) { renewed = true; await getToken(true); continue; }
    if ((res.status === 429 || res.status >= 500) && attempt < 6) {
      const wait = Number(res.headers.get("retry-after")) || 30 * 2 ** attempt;
      console.error(`${res.status}, waiting ${wait}s`);
      await sleep(wait * 1000);
      continue;
    }
    throw new Error(`${res.status} from ${path}: ${(await res.text()).slice(0, 500)}`);
  }
}

const country = `countryCode=${opts.country}`;
const okRow = (id, a) => ({ tidal: id, status: "ok", id: String(a.id), name: a.attributes?.name ?? "" });
const notFound = (id) => ({ tidal: id, status: "not found", id: "", name: "" });

async function lookupBatch(ids) {
  for (const id of ids) if (!/^\d+$/.test(id)) throw new Error(`not a numeric Tidal ID: ${id}`);
  const { status, body } = await api(`/artists?${country}&${ids.map((id) => `filter%5Bid%5D=${id}`).join("&")}`);
  if (status === 200) {
    const byId = new Map((body.data ?? []).filter((a) => a.type === "artists").map((a) => [String(a.id), a]));
    return ids.map((id) => (byId.has(id) ? okRow(id, byId.get(id)) : notFound(id)));
  }
  // The whole batch was rejected (404, or 400 for an ID the API won't take, like one past its
  // integer range): look the IDs up one by one, so only the bad ID fails.
  if (ids.length > 1) console.error(`batch answered ${status}, looking up its ${ids.length} IDs one by one`);
  const rows = [];
  for (const id of ids) {
    const one = await api(`/artists/${id}?${country}`);
    if (one.status === 200) rows.push(okRow(id, one.body.data));
    else if (one.status === 404) rows.push(notFound(id));
    else console.error(`${one.status} for Tidal ID ${id}: ${one.body}`);
  }
  return rows;
}

let ok = 0;
let missing = 0;
let failed = 0;
for (let i = 0; i < todo.length; i += 20) {
  const ids = todo.slice(i, i + 20);
  try {
    const rows = await lookupBatch(ids);
    failed += ids.length - rows.length;
    for (const row of rows) {
      appendFileSync(cachePath, tsvLine(COLS, row) + "\n");
      if (row.status === "ok") ok++;
      else missing++;
    }
  } catch (e) {
    failed += ids.length;
    console.error(e.message);
  }
  if ((i / 20) % 50 === 49) console.error(`${Math.min(i + 20, todo.length)}/${todo.length}`);
}
console.error(JSON.stringify({ lookedUp: ok + missing, ok, notFound: missing, failed }, null, 2));
if (failed) console.error("Some lookups failed and weren't recorded. Rerun to retry them.");
