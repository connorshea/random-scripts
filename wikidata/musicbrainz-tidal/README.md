# Tidal artist IDs from MusicBrainz

Scripts that generate QuickStatements batches adding Tidal artist ID (P4576) to items with a MusicBrainz artist ID (P434), using the Tidal links on MusicBrainz artists. Matches have to be one-to-one, and the Tidal artist's name (from the official TIDAL API) has to match the item's label. This is the same pipeline as `../musicbrainz-deezer`, with the TIDAL API in place of Deezer's.

Set `CONTACT_EMAIL` to the email address to put in the User-Agent header. The scripts that make requests won't run without it. If you run them somewhere that needs an HTTP proxy, also set `NODE_USE_ENV_PROXY=1` so Node's `fetch` uses it.

The name lookups also need a TIDAL developer app (https://developer.tidal.com/). Set its client credentials as `TIDAL_CLIENT_ID` and `TIDAL_CLIENT_SECRET`.

```sh
export CONTACT_EMAIL=you@example.com
export TIDAL_CLIENT_ID=...
export TIDAL_CLIENT_SECRET=...
```

## Input

The MusicBrainz JSON artist dump: `artist.tar.xz` from the newest folder at https://data.metabrainz.org/pub/musicbrainz/data/json-dumps/. The script reads `mbdump/artist` straight out of the archive with `tar -xOJf`, so you don't need to unpack it.

## Steps

Run these from a folder for the output files. `.tsv` and `.txt` files are gitignored.

1. `node fetch-wikidata.mjs .` queries QLever for every MusicBrainz artist ID and every Tidal artist ID on Wikidata, with their ranks, and writes `wd-mb.tsv` and `wd-tidal.tsv`.
2. `node match.mjs ~/Downloads/artist.tar.xz .` streams the dump, matches items to Tidal IDs through their MusicBrainz artists, and writes `candidates.tsv` and `match-skipped.tsv`.
3. `node tidal-names.mjs .` looks up the candidates' Tidal artists with the TIDAL API, 20 per request. It writes the results to `tidal-artists.tsv`. That file doubles as a cache, so you can stop the script and rerun it. It waits `--interval-ms` (default 1000) between requests, so about 40,000 IDs take around 35 minutes.
4. `node build-batch.mjs . --retrieved YYYY-MM-DD` checks the candidates against live Wikidata and the Tidal names. It writes `tidal-ids-001.qs.txt`, `tidal-ids-002.qs.txt`, … (10,000 commands each), plus `accepted.tsv` and `skipped.tsv`. Batch files from an earlier run are deleted first, so a rebuild never leaves a stale one behind. Pass the dump's date as `--retrieved`. It's the name of the dump's folder on data.metabrainz.org.

For a test run, pass `--limit N` to steps 3 and 4 to use only the first N candidates.

Each statement gets the reference matched by identifier from (P11797): MusicBrainz (Q14005), MusicBrainz artist ID (P434) and retrieved (P813):

```
Q123	P4576	"7804"	S11797	Q14005	S434	"<mbid>"	S813	+2026-10-31T00:00:00Z/11	/* import Tidal artist ID (P4576) from MusicBrainz */
```

## Matching rules

`match.mjs` keeps a pair only when:

- the MusicBrainz artist has exactly one Tidal link (ended links are ignored), and no other MusicBrainz artist links to that Tidal ID
- the MBID is on exactly one item, and that item has no other MBID (deprecated statements don't count)
- if the MusicBrainz artist links to Wikidata, the link points at the same item
- the item has no Tidal artist ID of any rank, and the Tidal ID isn't on any other item

It recognizes Tidal links like `https://tidal.com/artist/7804`, with or without `www.`, `listen.` or `/browse/`, a trailing slash, or a query string. Links to `store.tidal.com`, albums and tracks are ignored. A few Tidal values on Wikidata are full URLs instead of IDs. Those are compared by the ID in the URL.

`build-batch.mjs` then drops a candidate when:

- TIDAL has no artist with the ID, or answers with a different artist ID
- live Wikidata shows the item was deleted or redirected, now has a Tidal artist ID, or no longer has exactly the one matched MBID
- the Wikidata Query Service shows the Tidal ID is now on another item. It's only minutes behind live edits, so this catches IDs added since the QLever snapshot.
- the item has no `en` or `mul` label, or the label doesn't match the Tidal artist's name

The names are compared with `normalize()` from `../musicbrainz-discogs/normalize.mjs`, plus a Levenshtein allowance of 2 (at most 20% of the longer name). That's the same rule as `../musicbrainz-deezer`.

## TIDAL API notes

- Tokens come from the client-credentials flow at `https://auth.tidal.com/v1/oauth2/token`. No scopes are needed to read artists.
- `GET https://openapi.tidal.com/v2/artists?filter[id]=…` takes at most 20 IDs. The key is repeated for each ID. Responses are JSON:API documents, with the name in `data[].attributes.name`.
- An ID missing from a batch response is recorded as "not found" (the API leaves unknown IDs out rather than failing). If a whole batch answers 404 or 400, the script looks its IDs up one at a time with `GET /v2/artists/<id>`, so one bad ID only fails itself. IDs past the API's integer range get a 400 ("Must be a positive integer").
- Lookups are made for one country (`--country`, default `US`). An artist that isn't available there may come back as not found.
- TIDAL doesn't publish rate limits. The script sends one request at a time and backs off on 429 (using `Retry-After` if there is one).
