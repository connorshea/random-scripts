# Deezer artist IDs from MusicBrainz

Scripts that generate QuickStatements batches adding Deezer artist ID (P2722) to items with a MusicBrainz artist ID (P434), using the Deezer links on MusicBrainz artists. Matches have to be one-to-one, and the Deezer artist's name (from the Deezer API) has to match the item's label.

Set `CONTACT_EMAIL` to the email address to put in the User-Agent header. The scripts that make requests won't run without it. If you run them somewhere that needs an HTTP proxy, also set `NODE_USE_ENV_PROXY=1` so Node's `fetch` uses it.

```sh
export CONTACT_EMAIL=you@example.com
```

## Input

The MusicBrainz JSON artist dump: `artist.tar.xz` from the newest folder at https://data.metabrainz.org/pub/musicbrainz/data/json-dumps/. The script reads `mbdump/artist` straight out of the archive with `tar -xOJf`, so you don't need to unpack it.

## Steps

Run these from a folder for the output files. `.tsv` and `.txt` files are gitignored.

1. `node fetch-wikidata.mjs .` queries QLever for every MusicBrainz artist ID and every Deezer artist ID on Wikidata, with their ranks, and writes `wd-mb.tsv` and `wd-deezer.tsv`.
2. `node match.mjs ~/Downloads/artist.tar.xz .` streams the dump, matches items to Deezer IDs through their MusicBrainz artists, and writes `candidates.tsv` and `match-skipped.tsv`.
3. `node deezer-names.mjs .` looks up each candidate's Deezer artist with the public API (`https://api.deezer.com/artist/<id>`, which needs no key). It writes the results to `deezer-artists.tsv`. That file doubles as a cache, so you can stop the script and rerun it. It sends at most 9 requests a second, so about 36,000 lookups take a little over an hour.
4. `node build-batch.mjs . --retrieved YYYY-MM-DD` checks the candidates against current Wikidata and the Deezer names. It writes `deezer-ids-001.qs.txt`, `deezer-ids-002.qs.txt`, … (10,000 commands each), plus `accepted.tsv` and `skipped.tsv`. Batch files from an earlier run are deleted first, so a rebuild never leaves a stale one behind. Pass the dump's date as `--retrieved`. It's the name of the dump's folder on data.metabrainz.org.

   Current Wikidata comes from QLever, which applies Wikidata's edit stream to its index and is normally seconds behind. The script first compares the newest edit time on QLever with the clock. If QLever is more than `--max-lag-minutes` behind (default 60), it falls back to the Wikidata API (`wbgetentities`, 50 items at a time, about 15–20 minutes for 37,000 items) and reads the Deezer IDs from the Wikidata Query Service. `--source qlever` or `--source api` forces one or the other. QLever queries are a minute apart, so the QLever path takes about 3 minutes.

For a test run, pass `--limit N` to steps 3 and 4 to use only the first N candidates.

Each statement gets the reference matched by identifier from (P11797): MusicBrainz (Q14005), MusicBrainz artist ID (P434) and retrieved (P813):

```
Q123	P2722	"27"	S11797	Q14005	S434	"<mbid>"	S813	+2026-10-31T00:00:00Z/11	/* import Deezer artist ID (P2722) from MusicBrainz */
```

## Matching rules

`match.mjs` keeps a pair only when:

- the MusicBrainz artist has exactly one Deezer link (ended links are ignored), and no other MusicBrainz artist links to that Deezer ID
- the MBID is on exactly one item, and that item has no other MBID (deprecated statements don't count)
- if the MusicBrainz artist links to Wikidata, the link points at the same item
- the item has no Deezer artist ID of any rank, and the Deezer ID isn't on any other item

It recognizes Deezer links like `https://www.deezer.com/artist/27`, with or without a locale (`/en/`, `/fr/`), the `api.` host, or a query string like `?autoplay=true`.

`build-batch.mjs` then drops a candidate when:

- Deezer has no artist with the ID, or answers with a different artist ID
- the item was deleted or redirected, or no longer has exactly the one matched MBID. QLever can't tell these apart, so with QLever they're reported as one reason.
- the item now has a Deezer artist ID, or the Deezer ID is now on another item
- the item has no `en` or `mul` label, or the label doesn't match the Deezer artist's name

The names are compared with `normalize()` from `../musicbrainz-discogs/normalize.mjs`, the same check the MusicBrainz/Discogs artist scripts use. It ignores case, accents on Latin letters, quote and dash styles, punctuation, and "and" vs "&". The `en` label is used if the item has one, and the `mul` label otherwise. After normalizing, names within a Levenshtein distance of 2 also match, as long as the distance is no more than 20% of the longer name's length. That's the same rule as `../iswc-musicbrainz`, and it accepts `Ultramagnetic MCs`/`Ultramagnetic MC's` but not `Hi`/`חי`.

## Deezer API notes

- Only numeric IDs are ever sent. Given something else, like `/artist/abc`, Deezer searches by name and returns whatever artist it finds.
- A missing artist comes back as `{"error":{"type":"DataException","message":"no data","code":800}}` with HTTP 200.
- If Deezer answers "Quota limit exceeded" (error code 4), the script backs off and retries.
