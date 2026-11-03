// Shared helpers for the MusicBrainz/Discogs label ID scripts.

import { readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

// Wikimedia's and MusicBrainz's user-agent policies ask for contact details, so the scripts read an
// email address from the CONTACT_EMAIL environment variable. It's checked on the first request.
export function userAgent() {
  const email = process.env.CONTACT_EMAIL;
  if (!email) {
    console.error("Set CONTACT_EMAIL to an email address to include in the User-Agent header.");
    process.exit(1);
  }
  return `random-scripts-musicbrainz-discogs-labels/1.0 (${email})`;
}

// GET or POST a URL and parse the JSON. 429 and 5xx back off (Retry-After if given, else 30 s,
// doubling). With allow404, a 404 returns null instead of throwing.
export async function fetchJson(url, init = {}, { allow404 = false } = {}, attempt = 0) {
  const res = await fetch(url, { ...init, headers: { "User-Agent": userAgent(), Accept: "application/json", ...init.headers } });
  if (res.status === 429 || res.status === 503 || res.status >= 500) {
    if (attempt >= 6) throw new Error(`${res.status} from ${url}`);
    const wait = Number(res.headers.get("retry-after")) || 30 * 2 ** attempt;
    console.error(`${res.status}, waiting ${wait}s`);
    await sleep(wait * 1000);
    return fetchJson(url, init, { allow404 }, attempt + 1);
  }
  if (allow404 && res.status === 404) return null;
  if (!res.ok) throw new Error(`${res.status} from ${url}: ${(await res.text()).slice(0, 500)}`);
  return res.json();
}

// Run a query on QLever's Wikidata endpoint and return the bindings. Fails if QLever sends fewer
// rows than the result has.
export async function qlever(query) {
  const body = await fetchJson("https://qlever.dev/api/wikidata", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/sparql-results+json" },
    body: new URLSearchParams({ query }),
  });
  const total = body.meta?.["result-size-total"];
  if (total !== undefined && total !== body.results.bindings.length) {
    throw new Error(`QLever sent ${body.results.bindings.length} of ${total} rows`);
  }
  return body.results.bindings;
}

export const qidOf = (uri) => uri.split("/").pop();


const clean = (v) => String(v ?? "").replace(/[\t\n\r]/g, " ");
export const tsvLine = (cols, row) => cols.map((c) => clean(row[c])).join("\t");

export function writeTsv(path, cols, rows) {
  writeFileSync(path, [cols.join("\t"), ...rows.map((r) => tsvLine(cols, r))].join("\n") + "\n");
}

export function readTsv(path) {
  const [header, ...lines] = readFileSync(path, "utf8").trimEnd().split("\n");
  const cols = header.split("\t");
  return lines.map((l) => {
    const f = l.split("\t");
    return Object.fromEntries(cols.map((c, i) => [c, f[i] ?? ""]));
  });
}

// Group rows by a column: Map(key -> [value]).
export function groupBy(rows, key, value) {
  const m = new Map();
  for (const r of rows) (m.get(r[key]) ?? m.set(r[key], []).get(r[key])).push(value(r));
  return m;
}

// Read a stream line by line, splitting on \n only. Some MusicBrainz annotations contain a raw \r,
// which readline would treat as a line break.
export async function* lines(stream) {
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
