// Generate a QuickStatements batch that rewrites ISWC (P1827) values from the compact form
// "T1234567890" to the canonical "T-123.456.789-0" required by the property's format constraint.
//
// QuickStatements can't change a statement's value in place, so each statement is re-added with the
// new value, carrying over its rank, qualifiers and references, and the old statement is then removed
// by its ID. The batch uses QuickStatements 3.0 syntax (https://qs-dev.toolforge.org) for the rank
// keywords (R+/R-) and multiple references per line (!S). QS 3.0 runs consecutive commands on the same
// item as one edit, so each item's fix shows up as a single edit in its history.
//
// Statements are skipped when the check digit is wrong, the item already has the canonical value, or
// a qualifier/reference uses a datatype this script doesn't know how to write.
//
// Usage: CONTACT_EMAIL=you@example.com node fix-iswc-format.mjs [out-dir]
// Writes <out-dir>/iswc-format.qs3.txt and <out-dir>/skipped.tsv

import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const email = process.env.CONTACT_EMAIL;
if (!email) {
  console.error("Set CONTACT_EMAIL to an email address to include in the User-Agent header.");
  process.exit(1);
}
const UA = `random-scripts-iswc-format/1.0 (${email})`;
const outDir = process.argv[2] ?? ".";

const CANONICAL = /^T-[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]$/;

async function fetchJson(url, init = {}, attempt = 0) {
  const res = await fetch(url, { ...init, headers: { "User-Agent": UA, Accept: "application/json", ...init.headers } });
  if (res.status === 429 || res.status >= 500) {
    if (attempt >= 5) throw new Error(`${res.status} from ${url}`);
    const wait = Number(res.headers.get("retry-after")) || 30 * 2 ** attempt;
    console.error(`${res.status}, waiting ${wait}s`);
    await sleep(wait * 1000);
    return fetchJson(url, init, attempt + 1);
  }
  if (!res.ok) throw new Error(`${res.status} from ${url}`);
  return res.json();
}

// "T1234567890", "t-123456789-0", "T 123 456 789 0" etc. -> "T-123.456.789-0", or null if it
// doesn't contain exactly ten digits after the T.
function canonicalize(value) {
  const m = value.trim().match(/^[Tt]\W*((?:\d\W*){10})$/);
  if (!m) return null;
  const d = m[1].replace(/\D/g, "");
  return `T-${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d[9]}`;
}

// ISWC check digit: 1 + sum(i * d_i) over the nine work digits, and the check digit brings the total
// to a multiple of 10.
function checkDigitOk(canonical) {
  const d = canonical.replace(/\D/g, "");
  let sum = 1;
  for (let i = 0; i < 9; i++) sum += (i + 1) * Number(d[i]);
  return (10 - (sum % 10)) % 10 === Number(d[9]);
}

// 1. Find items with a non-canonical ISWC. QLever is quick and has no per-minute limit.
const query = `PREFIX p: <http://www.wikidata.org/prop/>
PREFIX ps: <http://www.wikidata.org/prop/statement/>
SELECT DISTINCT ?item WHERE {
  ?item p:P1827/ps:P1827 ?v .
  FILTER(!REGEX(?v, "^T-[0-9]{3}\\\\.[0-9]{3}\\\\.[0-9]{3}-[0-9]$"))
}`;
const sparql = await fetchJson("https://qlever.dev/api/wikidata", {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/sparql-results+json" },
  body: new URLSearchParams({ query }),
});
const qids = sparql.results.bindings.map((b) => b.item.value.split("/").pop());
console.error(`${qids.length} items with a non-canonical ISWC`);

// 2. Fetch the live statements from Wikidata, so qualifiers, references and ranks are current.
const API = "https://www.wikidata.org/w/api.php";
const entities = {};
for (let i = 0; i < qids.length; i += 50) {
  const params = new URLSearchParams({
    action: "wbgetentities",
    ids: qids.slice(i, i + 50).join("|"),
    props: "claims",
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
  console.error(`fetched ${Math.min(i + 50, qids.length)}/${qids.length}`);
  await sleep(500);
}

// Snak -> QuickStatements v1 value. Throws on datatypes this script doesn't handle.
const qsString = (s) => {
  if (s.includes('"') || /[\t\n]/.test(s)) throw new Error(`can't quote string ${JSON.stringify(s)}`);
  return `"${s}"`;
};
function snakValue(snak) {
  if (snak.snaktype === "somevalue") return "somevalue";
  if (snak.snaktype === "novalue") return "novalue";
  const { type, value } = snak.datavalue;
  switch (type) {
    case "string":
      return qsString(value);
    case "wikibase-entityid":
      return value.id;
    case "time":
      if (value.calendarmodel !== "http://www.wikidata.org/entity/Q1985727") throw new Error("non-Gregorian date");
      return `${value.time}/${value.precision}`;
    case "monolingualtext":
      return `${value.language}:${qsString(value.text)}`;
    case "quantity": {
      if (value.upperBound !== undefined || value.lowerBound !== undefined) throw new Error("quantity with bounds");
      const unit = value.unit === "1" ? "" : `U${value.unit.split("/").pop().replace(/^Q/, "")}`;
      return `${value.amount}${unit}`;
    }
    case "globecoordinate":
      if (value.globe !== "http://www.wikidata.org/entity/Q2") throw new Error("non-Earth coordinate");
      return `@${value.latitude}/${value.longitude}`;
    default:
      throw new Error(`unsupported datavalue type ${type}`);
  }
}

const SUMMARY = "/* normalize ISWC (P1827) format */";
const lines = [];
const skipped = [];
let fixed = 0;

for (const qid of qids) {
  const entity = entities[qid];
  if (!entity || entity.missing !== undefined) {
    skipped.push({ qid, reason: "item missing" });
    continue;
  }
  if (entity.id !== qid) {
    skipped.push({ qid, reason: `redirected to ${entity.id}` });
    continue;
  }
  const statements = entity.claims?.P1827 ?? [];
  const existing = new Set(statements.map((s) => s.mainsnak.datavalue?.value));
  for (const st of statements) {
    const old = st.mainsnak.datavalue?.value;
    if (old === undefined || CANONICAL.test(old)) continue;
    const skip = (reason) => skipped.push({ qid, statement: st.id, value: old, reason });

    const value = canonicalize(old);
    if (!value) { skip("not an ISWC with 10 digits"); continue; }
    if (!checkDigitOk(value)) { skip(`check digit wrong (${value})`); continue; }
    if (existing.has(value)) { skip(`item already has ${value}, remove the duplicate by hand`); continue; }

    try {
      const qualifiers = (st["qualifiers-order"] ?? []).flatMap((p) => st.qualifiers[p].map((q) => `\t${p}\t${snakValue(q)}`));
      // Each reference after the first starts with !S so it becomes a separate reference block
      const references = (st.references ?? []).map((ref, i) =>
        ref["snaks-order"]
          .flatMap((p) => ref.snaks[p].map((s) => [p.replace(/^P/, "S"), snakValue(s)]))
          .map(([prop, val], j) => `\t${i > 0 && j === 0 ? "!" : ""}${prop}\t${val}`)
          .join(""),
      );
      const rank = { preferred: "\tR+", deprecated: "\tR-", normal: "" }[st.rank];
      lines.push(`${qid}\tP1827\t"${value}"${rank}${qualifiers.join("")}${references.join("")}\t${SUMMARY}`);
      lines.push(`-STATEMENT\t${st.id}\t${SUMMARY}`);
      fixed++;
    } catch (e) {
      skip(e.message);
    }
  }
}

writeFileSync(join(outDir, "iswc-format.qs3.txt"), lines.join("\n") + "\n");
const cols = ["qid", "statement", "value", "reason"];
writeFileSync(
  join(outDir, "skipped.tsv"),
  [cols.join("\t"), ...skipped.map((r) => cols.map((k) => r[k] ?? "").join("\t"))].join("\n") + "\n",
);

const reasons = {};
for (const s of skipped) {
  const key = s.reason.replace(/ \(.*\)$/, "").replace(/item already has .*/, "item already has the canonical value").replace(/^can.t quote string .*/, "qualifier or reference string contains a double quote");
  reasons[key] = (reasons[key] ?? 0) + 1;
}
console.error(JSON.stringify({ items: qids.length, statementsFixed: fixed, qsLines: lines.length, skipped: reasons }, null, 2));
