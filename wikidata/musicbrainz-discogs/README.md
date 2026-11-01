# MusicBrainz and Discogs artist IDs

Scripts for generating QuickStatements batches that fill in missing artist IDs on Wikidata from the MusicBrainz and Discogs data dumps. The matches are one-to-one only, and every statement gets a reference saying which ID it was matched through.

There are two directions:

- **MusicBrainz artist IDs (P434)** for items that have a Discogs artist ID (P1953) but no MusicBrainz ID.
- **Discogs artist IDs (P1953)** for items that have a MusicBrainz artist ID (P434) but no Discogs ID.

Requests go to [QLever's Wikidata endpoint](https://qlever.dev/wikidata), one at a time with a 5 second pause, backing off on 429s and server errors. Set `CONTACT_EMAIL` to the email address to put in the User-Agent header. The scripts won't run without it.

```sh
export CONTACT_EMAIL=you@example.com
```

## Inputs

- The MusicBrainz JSON artist dump, `artist.tar.xz` from https://data.metabrainz.org/pub/musicbrainz/data/json-dumps/. It's streamed out of the archive with `tar -xOJf`, so it never has to be unpacked.
- The Discogs artist dump, `discogs_YYYYMMDD_artists.xml.gz` from https://data.discogs.com/ (only needed for the Discogs ID direction). It's opened read-only and streamed.
- Query results saved as TSV from QLever or the Wikidata Query Service, from the `.rq` files in this folder.

## MusicBrainz artist IDs (P434)

1. Run `wd-discogs-no-mb.rq` and save the result as `wd-discogs-no-mb.tsv`.
2. Match MusicBrainz artists to the items through their Discogs links:
   ```sh
   tar -xOJf ~/Downloads/artist.tar.xz mbdump/artist | node match.mjs wd-discogs-no-mb.tsv > candidates.json
   ```
   This keeps a pair only when the item has exactly one Discogs ID that no other item has, the MusicBrainz artist has exactly one Discogs link that no other MusicBrainz artist has, and any Wikidata link on the MusicBrainz artist points at the same item.
3. `node finalize.mjs candidates.json .` compares the item's English label (or `mul` label) with the MusicBrainz name, drops MusicBrainz IDs that are already on an item, and writes `mb-artist-ids.qs.tsv`, `accepted.tsv` and `rejected.tsv`.
4. Optional checks:
   - `node types.mjs mb-artist-ids.qs.tsv` lists items that aren't a human or musical group in `not-human-or-group.tsv`, so they can be reviewed or filtered out.
   - `node verify.mjs` cross-checks the batch against the inputs and against live Wikidata. It expects the batch split into `mb-artist-ids.first20.qs.tsv` and `mb-artist-ids.rest.qs.tsv`.

Each statement gets the reference matched by identifier from (P11797): Discogs (Q504063), Discogs artist ID (P1953) and retrieved (P813).

## Discogs artist IDs (P1953)

1. Run `wd-mb-no-discogs.rq` and `wd-all-discogs.rq` on QLever and save the results as `wd-mb-no-discogs.tsv` and `wd-all-discogs.tsv`.
2. Find MusicBrainz artists with exactly one Discogs link that isn't on Wikidata yet:
   ```sh
   tar -xOJf ~/Downloads/artist.tar.xz mbdump/artist | node reverse-match.mjs wd-mb-no-discogs.tsv wd-all-discogs.tsv > reverse-candidates.json
   ```
3. `node discogs-names.mjs ~/Downloads/discogs_YYYYMMDD_artists.xml.gz reverse-candidates.json` compares the MusicBrainz name with the Discogs name, name variations and real name, and writes `reverse-name-check.tsv`.
4. `node reverse-build.mjs` keeps the name matches, keeps only humans, musical groups (and subclasses), musical ensembles, orchestras, duos and musical trios, checks the IDs are still missing on live Wikidata, and writes `discogs-ids.qs.tsv`.
5. `node label-check.mjs ~/Downloads/discogs_YYYYMMDD_artists.xml.gz` also requires the item's English (or `mul`) label to match the Discogs name, a name variation or the real name, and writes `discogs-ids.label-checked.qs.tsv`. This is the batch to run.
6. Optional: `node analyze-misses.mjs ~/Downloads/discogs_YYYYMMDD_artists.xml.gz` measures how many of the label check's misses some looser matching rules would recover.

Each statement gets the reference matched by identifier from (P11797): MusicBrainz (Q14005), MusicBrainz artist ID (P434) and retrieved (P813).

## Name matching

All name comparisons go through `normalize.mjs`. It ignores case, accents on Latin letters, quote and dash styles, extra spaces, punctuation and "and" vs "&", and it strips Discogs' numbered suffix like " (3)". Word order and a leading "The" still count.

## Notes

- QuickStatements 3.0 sends edits through the Wikibase REST API and doesn't check maxlag, so pause big batches yourself when the query service lag is high.
- Very large batches may need splitting before QuickStatements will take them. 30,000 lines in one file was too many.
