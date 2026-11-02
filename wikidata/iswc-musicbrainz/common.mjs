// Shared helpers for the ISWC import scripts.

import { readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

// Wikimedia's user-agent policy asks for contact details, so the scripts read an email address from
// the CONTACT_EMAIL environment variable.
// It's checked on the first request, so extract-iswcs.mjs (which makes none) runs without it.
function userAgent() {
  const email = process.env.CONTACT_EMAIL;
  if (!email) {
    console.error("Set CONTACT_EMAIL to an email address to include in the User-Agent header.");
    process.exit(1);
  }
  return `random-scripts-iswc-musicbrainz/1.0 (${email})`;
}

export async function fetchJson(url, init = {}, attempt = 0) {
  const UA = userAgent();
  const res = await fetch(url, { ...init, headers: { "User-Agent": UA, Accept: "application/json", ...init.headers } });
  if (res.status === 429 || res.status >= 500) {
    if (attempt >= 6) throw new Error(`${res.status} from ${url}`);
    const wait = Number(res.headers.get("retry-after")) || 30 * 2 ** attempt;
    console.error(`${res.status}, waiting ${wait}s`);
    await sleep(wait * 1000);
    return fetchJson(url, init, attempt + 1);
  }
  if (!res.ok) throw new Error(`${res.status} from ${url}: ${(await res.text()).slice(0, 500)}`);
  return res.json();
}

// Run a query on QLever's Wikidata endpoint and return the bindings.
export async function qlever(query) {
  const body = await fetchJson("https://qlever.dev/api/wikidata", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/sparql-results+json" },
    body: new URLSearchParams({ query }),
  });
  // Fail loudly if QLever ever sends fewer rows than the result has, instead of silently missing
  // candidates or existing ISWCs.
  const total = body.meta?.["result-size-total"];
  if (total !== undefined && total !== body.results.bindings.length) {
    throw new Error(`QLever sent ${body.results.bindings.length} of ${total} rows`);
  }
  return body.results.bindings;
}

export const qidOf = (uri) => uri.split("/").pop();

// "T1234567890", "t-123456789-0", "T 123 456 789 0" etc. -> "T-123.456.789-0", or null if it
// doesn't contain exactly ten digits after the T.
export function canonicalizeIswc(value) {
  const m = value.trim().match(/^[Tt]\W*((?:\d\W*){10})$/);
  if (!m) return null;
  const d = m[1].replace(/\D/g, "");
  return `T-${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d[9]}`;
}

// ISWC check digit: 1 + sum(i * d_i) over the nine work digits, and the check digit brings the total
// to a multiple of 10.
export function iswcCheckDigitOk(canonical) {
  const d = canonical.replace(/\D/g, "");
  let sum = 1;
  for (let i = 0; i < 9; i++) sum += (i + 1) * Number(d[i]);
  return (10 - (sum % 10)) % 10 === Number(d[9]);
}

// Levenshtein distance between two strings, counted in code points.
export function levenshtein(a, b) {
  a = [...a];
  b = [...b];
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[b.length];
}

const clean =(v) => String(v ?? "").replace(/[\t\n\r]/g, " ");

export function writeTsv(path, cols, rows) {
  writeFileSync(path, [cols.join("\t"), ...rows.map((r) => cols.map((c) => clean(r[c])).join("\t"))].join("\n") + "\n");
}

export function readTsv(path) {
  const [header, ...lines] = readFileSync(path, "utf8").trimEnd().split("\n");
  const cols = header.split("\t");
  return lines.map((l) => {
    const f = l.split("\t");
    return Object.fromEntries(cols.map((c, i) => [c, f[i] ?? ""]));
  });
}
