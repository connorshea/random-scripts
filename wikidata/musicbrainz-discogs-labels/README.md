# MusicBrainz and Discogs label IDs

Scripts that generate QuickStatements batches filling in missing label IDs on Wikidata from the MusicBrainz label dump, in both directions:

- **Discogs label ID (P1955)** for items that have a MusicBrainz label ID (P966) but no Discogs label ID.
- **MusicBrainz label ID (P966)** for items that have a Discogs label ID but no MusicBrainz label ID.

Both directions go through the Discogs links on MusicBrainz labels, and the matches have to be one-to-one. The item's label also has to match the name on the side being added. This is the label version of `../musicbrainz-discogs`, written in the style of `../musicbrainz-tidal`.

Set `CONTACT_EMAIL` to the contact to put in the User-Agent header. The scripts that make requests won't run without it. If you run them somewhere that needs an HTTP proxy, also set `NODE_USE_ENV_PROXY=1` so Node's `fetch` uses it.

```sh
export CONTACT_EMAIL=you@example.com
```

## Inputs

- The MusicBrainz JSON label dump: `label.tar.xz` from the newest folder at https://data.metabrainz.org/pub/musicbrainz/data/json-dumps/. It's streamed out of the archive with `tar -xOJf`, so you don't need to unpack it.
- The Discogs labels dump: `discogs_YYYYMMDD_labels.xml.gz` from https://data.discogs.com/. It's opened read-only and streamed.

## Steps

Run these from a folder for the output files. `.tsv` and `.txt` files are gitignored.

1. `node fetch-wikidata.mjs .` queries QLever for every P966 and P1955 statement, with ranks, and writes `wd-mb.tsv` and `wd-discogs.tsv`. Existing files are kept, so delete them to refetch.
2. `node match.mjs ~/Downloads/label.tar.xz .` streams the MusicBrainz dump and writes `candidates.tsv` (both directions, told apart by the `direction` column) and `match-skipped.tsv`.
3. `node discogs-names.mjs ~/Downloads/discogs_YYYYMMDD_labels.xml.gz .` writes `discogs-labels.tsv` with the Discogs name of each candidate's Discogs ID.
4. `node build-batch.mjs . --retrieved YYYY-MM-DD` checks the candidates against live Wikidata and the names. It writes `discogs-label-ids-001.qs.txt`, `mb-label-ids-001.qs.txt`, … (10,000 commands each), plus `accepted.tsv` and `skipped.tsv`. Batch files from an earlier run are deleted first. Pass the MusicBrainz dump's date as `--retrieved`. It's the name of the dump's folder on data.metabrainz.org.

Each statement gets the reference matched by identifier from (P11797), with the ID the match went through and retrieved (P813):

```
Q123	P1955	"193596"	S11797	Q14005	S966	"<mbid>"	S813	+2026-10-31T00:00:00Z/11	/* import Discogs label ID (P1955) from MusicBrainz */
Q456	P966	"<mbid>"	S11797	Q504063	S1955	"114809"	S813	+2026-10-31T00:00:00Z/11	/* import MusicBrainz label ID (P966) matched by Discogs label ID */
```

## What gets skipped

`match.mjs` keeps a pair only when:

- the MusicBrainz label has exactly one Discogs label link (ended links are ignored), and no other MusicBrainz label links to that Discogs ID
- any Wikidata link on the MusicBrainz label points at the same item
- the ID the match goes through is on exactly one item, and that item has no other value of it (deprecated statements are ignored)
- the item doesn't have the property being added (any rank), and the new ID isn't on another item (any rank)

It recognizes Discogs links like `https://www.discogs.com/label/67467`, with or without `www.`, a slug (`/label/67467-Name`), a language prefix, a trailing slash or a query string.

`build-batch.mjs` then drops a candidate when:

- live Wikidata shows the item was deleted or redirected, is an instance of human (Q5), now has the property being added, or no longer has exactly the one matched ID
- the Discogs ID isn't in the Discogs dump, so it was deleted or merged on Discogs (both directions)
- the item has no `en` or `mul` label, or the label doesn't match the name on the side being added. That's the Discogs name, without its numbered suffix like " (4)", for P1955, and the MusicBrainz name for P966.

Names are compared with `normalize()` from `../musicbrainz-discogs/normalize.mjs`. Trailing "Records", "Recordings", "Label(s)" or "Music" words and a company suffix (Ltd, Inc, LLC, GmbH) are dropped from both sides, so `Avatar Records` matches `Avatar` and `Naked Music` matches `Naked Music Recordings`. After that, names within a Levenshtein distance of 2 also match, as long as the distance is no more than 20% of the longer name.
