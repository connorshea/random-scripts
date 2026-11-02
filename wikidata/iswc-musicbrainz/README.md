# ISWCs from MusicBrainz

Scripts that generate QuickStatements batches adding ISWC (P1827) to musical work/composition items (Q105543609) that have a MusicBrainz work ID (P435) but no ISWC, using the ISWCs on the linked MusicBrainz work. Only items whose sole instance of (P31) is musical work/composition are used, and only when the item's name matches the MusicBrainz work's title.

Set `CONTACT_EMAIL` to the email address to put in the User-Agent header. The scripts that make requests won't run without it. If you run them somewhere that needs an HTTP proxy, also set `NODE_USE_ENV_PROXY=1` so Node's `fetch` uses it.

```sh
export CONTACT_EMAIL=you@example.com
```

## Input

The MusicBrainz JSON work dump: `work.tar.xz` from the newest folder at https://data.metabrainz.org/pub/musicbrainz/data/json-dumps/. The script reads `mbdump/work` straight out of the archive with `tar -xOJf`, so you don't need to unpack it.

## Steps

Run these from a folder for the output files. `.tsv` and `.txt` files are gitignored.

1. `node fetch-candidates.mjs .` queries QLever for the candidate items and writes `candidates.tsv` (qid, mbid). It also writes `existing-iswcs.tsv` with every ISWC already on Wikidata.
2. `node extract-iswcs.mjs ~/Downloads/work.tar.xz .` streams the dump and writes `mb-works.tsv` with the title, ISWCs and Wikidata links of each candidate MBID.
3. `node build-batch.mjs . --retrieved YYYY-MM-DD` writes `iswc-import-001.qs.txt`, `iswc-import-002.qs.txt`, … (10,000 commands each) and `skipped.tsv`. Pass the dump's date as `--retrieved`. It's the name of the dump's folder on data.metabrainz.org.

Each statement gets the reference stated in (P248) MusicBrainz (Q14005), MusicBrainz work ID (P435) and retrieved (P813):

```
Q123	P1827	"T-123.456.789-4"	S248	Q14005	S435	"<mbid>"	S813	+2026-10-28T00:00:00Z/11	/* import ISWC (P1827) from MusicBrainz */
```

## What gets skipped

`skipped.tsv` lists every ISWC or item left out, with the reason:

- The item has more than one MusicBrainz work ID (P435). Any statement that isn't deprecated counts.
- The MBID isn't in the dump, because the work was merged or deleted on MusicBrainz. The MBID on Wikidata probably needs updating.
- The MusicBrainz work links to a different Wikidata item.
- The MusicBrainz work has more ISWCs than `--max-iswcs` (default 1, so each item gets at most one ISWC).
- The ISWC is malformed or its check digit is wrong.
- The ISWC is already on another Wikidata item, or would be added to more than one item.
- Live Wikidata shows the item was deleted or redirected, now has an ISWC, or no longer has the MBID.
- The item has an instance of (P31) other than musical work/composition (Q105543609), counting every statement that isn't deprecated.
- The item has no `en` or `mul` label, or that label doesn't match the MusicBrainz work's title. The names are compared with `normalize()` from `../musicbrainz-discogs/normalize.mjs`, the same check the MusicBrainz/Discogs artist scripts use. It ignores case, accents on Latin letters, quote and dash styles, punctuation, and "and" vs "&". The `en` label is used if the item has one, and the `mul` label otherwise. After normalizing, names within a Levenshtein distance of 2 also match, as long as the distance is no more than 20% of the longer name's length. That accepts `Rockin'`/`Rocking`, `USA`/`U.S.A.` and `Marshmallow World`/`A Marshmallow World`, but not `Hi`/`חי`.

Items whose MusicBrainz work has no ISWC are only counted in the summary. They aren't listed in `skipped.tsv`.
