// Step 4: check the candidates against current Wikidata and the Tidal names, and write the
// QuickStatements batches.
//
// Usage: CONTACT_EMAIL=you@example.com node build-batch.mjs [dir] [--retrieved YYYY-MM-DD]
//          [--batch-size N] [--limit N] [--max-lag-minutes N] [--source auto|qlever|api]
//   --retrieved        date for the retrieved (P813) qualifier on the reference. Use the date of the
//                      MusicBrainz dump (the name of its folder on data.metabrainz.org). Defaults to
//                      today.
//   --batch-size       commands per output file (default 10000).
//   --limit            only use the first N candidates, for a test run.
//   --max-lag-minutes  how far behind live Wikidata QLever may be before falling back to the API
//                      (default 60).
//   --source           where to read current Wikidata from: auto (default) uses QLever if it's
//                      fresh enough and the API otherwise; qlever or api forces one.
//
// Reads <dir>/candidates.tsv and <dir>/tidal-artists.tsv. Writes <dir>/tidal-ids-NNN.qs.txt
// (QuickStatements v1), <dir>/accepted.tsv and <dir>/skipped.tsv. Batch files from an earlier run
// are deleted first.
//
// Current Wikidata comes from QLever, which applies Wikidata's edit stream to its index and is
// normally seconds behind. The script first compares the newest edit time QLever has with the
// clock. If QLever is more than --max-lag-minutes behind, it reads the items from the Wikidata API
// (wbgetentities, 50 at a time, slower) and the property's values from the Wikidata Query Service
// instead. QLever queries are a minute apart.
//
// Each statement gets the reference matched by identifier from (P11797): MusicBrainz (Q14005),
// MusicBrainz artist ID (P434) and retrieved (P813).
//
// A candidate is left out when:
//   - Tidal has no artist with the ID, or answers with a different artist ID
//   - the item is gone or redirected, or no longer has exactly one MBID (the matched one, not
//     counting deprecated statements). QLever can't tell these apart, so with QLever they share
//     one reason.
//   - the item now has a Tidal artist ID, or the Tidal ID is now on another item
//   - the item has no en or mul label, or that label doesn't match the Tidal artist's name. The
//     en label is used if there is one, and the mul label otherwise. Both names go through
//     normalize() from ../musicbrainz-discogs/normalize.mjs, and they match if the Levenshtein
//     distance between them is at most 2 and at most 20% of the longer one, the same rule as
//     ../iswc-musicbrainz ("Ultramagnetic MCs" ~ "Ultramagnetic MC's", but not "Hi" ~ "חי").

import { readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";
import { fetchJson, qlever, qidOf, readTsv, writeTsv } from "./common.mjs";
import { normalize } from "../musicbrainz-discogs/normalize.mjs";
import { levenshtein } from "../iswc-musicbrainz/common.mjs";

// What this script imports. The rest of the file is the same as ../musicbrainz-deezer/build-batch.mjs.
const PROP = "P4576";
const SERVICE = "Tidal";
const ID_COL = "tidal"; // column in candidates.tsv and the lookup cache
const CACHE = "tidal-artists.tsv";
const NAMES_SCRIPT = "tidal-names.mjs";
const BATCH_PREFIX = "tidal-ids";
// Some values on Wikidata are full URLs rather than IDs; compare them by the ID in the URL.
const idFromValue = (v) => v.match(/tidal\.com\/(?:browse\/)?artist\/(\d+)/)?.[1] ?? v;

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
    "max-lag-minutes": { type: "string", default: "60" },
    source: { type: "string", default: "auto" },
  },
});
const dir = positionals[0] ?? ".";
if (!/^\d{4}-\d{2}-\d{2}$/.test(opts.retrieved)) throw new Error("--retrieved must be YYYY-MM-DD");
const batchSize = Number(opts["batch-size"]);
if (!Number.isInteger(batchSize) || batchSize < 1) throw new Error("--batch-size must be a positive integer");
const limit = opts.limit === undefined ? Infinity : Number(opts.limit);
if (!(limit === Infinity || (Number.isInteger(limit) && limit > 0))) throw new Error("--limit must be a positive integer");
const maxLagMinutes = Number(opts["max-lag-minutes"]);
if (!(maxLagMinutes >= 0)) throw new Error("--max-lag-minutes must be a non-negative number");
if (!["auto", "qlever", "api"].includes(opts.source)) throw new Error("--source must be auto, qlever or api");

const candidates = readTsv(join(dir, "candidates.tsv")).slice(0, limit);
const lookups = new Map(readTsv(join(dir, CACHE)).map((r) => [r[ID_COL], r]));

const skipped = [];
const counts = {};
const skip = (c, reason, detail = "") => {
  skipped.push({ ...c, reason, detail });
  counts[reason] = (counts[reason] ?? 0) + 1;
};

// 1. The service's names
const remaining = [];
for (const c of candidates) {
  const d = lookups.get(c[ID_COL]);
  if (!d) skip(c, `not looked up on ${SERVICE} yet (rerun ${NAMES_SCRIPT})`);
  else if (d.status !== "ok") skip(c, `no ${SERVICE} artist with this ID`);
  else if (d.id !== c[ID_COL]) skip(c, `${SERVICE} answers with a different artist ID`, d.id);
  else remaining.push({ ...c, serviceName: d.name });
}
const qids = [...new Set(remaining.map((c) => c.qid))];

// 2. Current Wikidata. Both sources fill in the same shape:
//   items:     qid -> { mbids: non-deprecated MBIDs (lowercase), values: PROP values, label: en or
//              mul label }, or { gone: reason } when the API says the item is missing or redirected
//   idToItems: ID -> Set of items with it in PROP (any rank)
//   An item with no entry is gone, redirected or has no MBID (QLever can't tell which).
const PREFIXES = `PREFIX p: <http://www.wikidata.org/prop/>
PREFIX ps: <http://www.wikidata.org/prop/statement/>
PREFIX wikibase: <http://wikiba.se/ontology#>
PREFIX schema: <http://schema.org/>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
`;
const QLEVER_GAP_MS = 60_000; // one QLever query a minute

async function qleverLagMinutes() {
  const [b] = await qlever(`${PREFIXES}SELECT (MAX(?d) AS ?latest) WHERE { ?item schema:dateModified ?d }`);
  const latest = new Date(b.latest.value);
  if (Number.isNaN(latest.getTime())) throw new Error(`unexpected dateModified from QLever: ${b.latest.value}`);
  return { latest, lag: (Date.now() - latest.getTime()) / 60_000 };
}

async function fromQlever() {
  const wanted = new Set(qids);
  const items = new Map();
  await sleep(QLEVER_GAP_MS);
  console.error("reading MBIDs and labels from QLever");
  const rows = await qlever(`${PREFIXES}
SELECT ?item ?mbid ?en ?mul WHERE {
  ?item p:P434 ?st .
  ?st ps:P434 ?mbid ;
      wikibase:rank ?rank .
  FILTER(?rank != wikibase:DeprecatedRank)
  OPTIONAL { ?item rdfs:label ?en . FILTER(LANG(?en) = "en") }
  OPTIONAL { ?item rdfs:label ?mul . FILTER(LANG(?mul) = "mul") }
}`);
  for (const b of rows) {
    const qid = qidOf(b.item.value);
    if (!wanted.has(qid)) continue;
    const item = items.get(qid) ?? items.set(qid, { mbids: new Set(), values: [], label: b.en?.value ?? b.mul?.value }).get(qid);
    item.mbids.add(b.mbid.value.toLowerCase());
  }
  await sleep(QLEVER_GAP_MS);
  console.error(`reading ${PROP} from QLever`);
  const idToItems = new Map();
  for (const b of await qlever(`${PREFIXES}SELECT ?item ?value WHERE { ?item p:${PROP}/ps:${PROP} ?value }`)) {
    const qid = qidOf(b.item.value);
    const id = idFromValue(b.value.value);
    (idToItems.get(id) ?? idToItems.set(id, new Set()).get(id)).add(qid);
    items.get(qid)?.values.push(b.value.value);
  }
  return { items, idToItems };
}

async function fromApi() {
  const API = "https://www.wikidata.org/w/api.php";
  const items = new Map();
  console.error(`checking ${qids.length} items against the Wikidata API`);
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
    for (const [key, entity] of Object.entries(body.entities)) {
      if (entity.missing !== undefined) { items.set(key, { gone: "item missing" }); continue; }
      const claims = entity.claims ?? {};
      const state = {
        mbids: new Set((claims.P434 ?? []).filter((s) => s.rank !== "deprecated").map((s) => s.mainsnak.datavalue?.value?.toLowerCase())),
        values: (claims[PROP] ?? []).map((s) => s.mainsnak.datavalue?.value).filter(Boolean),
        label: entity.labels?.en?.value ?? entity.labels?.mul?.value,
      };
      items.set(entity.id, state);
      // A redirect is answered under the target's ID; mark the requested ID as redirected.
      if (key !== entity.id) items.set(key, { gone: `item redirected to ${entity.id}` });
    }
    if ((i / 50) % 50 === 0) console.error(`fetched ${Math.min(i + 50, qids.length)}/${qids.length}`);
    await sleep(500);
  }
  // The property's values on every item, from the Wikidata Query Service (minutes behind live).
  console.error(`reading ${PROP} from the Wikidata Query Service`);
  const wdqs = await fetchJson("https://query.wikidata.org/sparql", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/sparql-results+json" },
    body: new URLSearchParams({ query: `SELECT ?item ?value WHERE { ?item p:${PROP}/ps:${PROP} ?value }` }),
  });
  const idToItems = new Map();
  for (const b of wdqs.results.bindings) {
    const id = idFromValue(b.value.value);
    (idToItems.get(id) ?? idToItems.set(id, new Set()).get(id)).add(qidOf(b.item.value));
  }
  return { items, idToItems };
}

let source = opts.source;
if (source !== "api") {
  const { latest, lag } = await qleverLagMinutes();
  console.error(`QLever's newest edit is from ${latest.toISOString()}, ${lag.toFixed(1)} minutes ago`);
  if (source === "auto") source = lag <= maxLagMinutes ? "qlever" : "api";
  if (source === "api") console.error(`more than ${maxLagMinutes} minutes behind, using the Wikidata API instead`);
}
const { items, idToItems } = source === "qlever" ? await fromQlever() : await fromApi();

// 3. Decide
const SUMMARY = `/* import ${SERVICE} artist ID (${PROP}) from MusicBrainz */`;
const retrieved = `+${opts.retrieved}T00:00:00Z/11`;
const lines = [];
const accepted = [];
for (const c of remaining) {
  const id = c[ID_COL];
  const item = items.get(c.qid);
  if (!item) { skip(c, source === "qlever" ? "item gone, redirected or without an MBID" : "item missing"); continue; }
  if (item.gone) { skip(c, item.gone); continue; }
  if (item.values.length) { skip(c, `item now has a ${SERVICE} artist ID`, item.values.join(",")); continue; }
  if (item.mbids.size !== 1 || !item.mbids.has(c.mbid)) { skip(c, "item's MBIDs changed", [...item.mbids].join(",")); continue; }
  if (!item.label) { skip(c, "no en or mul label"); continue; }
  if (!namesMatch(item.label, c.serviceName)) { skip(c, "name mismatch", `${item.label} | ${c.serviceName}`); continue; }
  const others = [...(idToItems.get(id) ?? [])].filter((q) => q !== c.qid);
  if (others.length) { skip(c, `${SERVICE} ID now on another item`, others.join(",")); continue; }
  lines.push(`${c.qid}\t${PROP}\t"${id}"\tS11797\tQ14005\tS434\t"${c.mbid}"\tS813\t${retrieved}\t${SUMMARY}`);
  accepted.push({ ...c, wdLabel: item.label });
}

// 4. Write the batches and reports.
// Remove batches from an earlier run first, so a rebuild with fewer files doesn't leave a stale one.
const batchFile = new RegExp(`^${BATCH_PREFIX}-\\d{3}\\.qs\\.txt$`);
for (const f of readdirSync(dir)) if (batchFile.test(f)) rmSync(join(dir, f));
const files = [];
for (let i = 0; i < lines.length; i += batchSize) {
  const name = `${BATCH_PREFIX}-${String(i / batchSize + 1).padStart(3, "0")}.qs.txt`;
  writeFileSync(join(dir, name), lines.slice(i, i + batchSize).join("\n") + "\n");
  files.push(name);
}
const nameCol = `${ID_COL}Name`;
writeTsv(join(dir, "accepted.tsv"), ["qid", "wdLabel", nameCol, "mbName", ID_COL, "mbid"], accepted.map((a) => ({ ...a, [nameCol]: a.serviceName })));
writeTsv(join(dir, "skipped.tsv"), ["qid", "mbid", ID_COL, "mbName", nameCol, "reason", "detail"], skipped.map((s) => ({ ...s, [nameCol]: s.serviceName })));
console.error(JSON.stringify({ source, candidates: candidates.length, statements: lines.length, files, skipped: counts }, null, 2));
