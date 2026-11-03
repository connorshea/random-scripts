# ISRCs from MusicBrainz

Scripts that generate QuickStatements batches adding ISRC (P1243) to track items that have a MusicBrainz recording ID (P4404) but no ISRC, using the ISRCs on the linked MusicBrainz recording. Only items whose every instance of (P31) is music track with vocals (Q55850593), music track without lyrics (Q55850643) or audio track (Q7302866) are used. Those are the types P1243's constraints allow. Items with a MusicBrainz work ID (P435) or ISWC (P1827) are left out, since P1243 conflicts with both. An item is only edited when its name matches the MusicBrainz recording's title.

Set `CONTACT_EMAIL` to the contact to put in the User-Agent header. The scripts won't run without it. If you run them somewhere that needs an HTTP proxy, also set `NODE_USE_ENV_PROXY=1` so Node's `fetch` uses it.

```sh
export CONTACT_EMAIL=you@example.com
```

## Why the search API and not a dump

The ISWC import reads the work dump, but there's no small dump for this. `recording.tar.xz` only holds standalone recordings (about 157,000, which covered 13 of 6,952 candidates on 2026-11-02). Recordings on releases are only in the 23 GB `release.tar.xz`. So step 2 uses the MusicBrainz search API with 100 MBIDs per request, which is about 70 requests for all candidates.

## Steps

Run these from a folder for the output files. `.tsv` and `.txt` files are gitignored.

1. `node fetch-candidates.mjs .` queries QLever for the candidate items and writes `candidates.tsv` (qid, mbid). It also writes `existing-isrcs.tsv` with every ISRC already on Wikidata.
2. `node search-recordings.mjs .` searches MusicBrainz for the candidate MBIDs and writes `mb-recordings.tsv` (mbid, title, isrcs).
3. `node build-batch.mjs . --retrieved YYYY-MM-DD` writes `isrc-import-001.qs.txt`, `isrc-import-002.qs.txt`, … (10,000 commands each) and `skipped.tsv`. Batch files from an earlier run are deleted first. Pass the day step 2 ran as `--retrieved`.

Each statement gets the reference stated in (P248) MusicBrainz (Q14005), MusicBrainz recording ID (P4404) and retrieved (P813):

```
Q123	P1243	"USRC17607839"	S248	Q14005	S4404	"<mbid>"	S813	+2026-11-02T00:00:00Z/11	/* import ISRC (P1243) from MusicBrainz */
```

## What gets skipped

`skipped.tsv` lists every ISRC or item left out, with the reason:

- The item has more than one MusicBrainz recording ID (P4404). Any statement that isn't deprecated counts.
- The search didn't return the MBID. The recording was merged or deleted on MusicBrainz (search doesn't follow merges), so the MBID on Wikidata probably needs updating.
- The MusicBrainz recording has more ISRCs than `--max-isrcs` (default 1). Recordings often have several valid ISRCs from reissues, but a long list is more likely to include a wrong one.
- The ISRC is malformed.
- The ISRC is already on another Wikidata item, or would be added to more than one item. P1243 has a distinct-values constraint.
- Live Wikidata shows the item was deleted or redirected, now has an ISRC, MusicBrainz work ID or ISWC, no longer has the MBID, or has an instance of (P31) that isn't one of the three track types.
- The item has no `en` or `mul` label, or that label doesn't match the MusicBrainz recording's title. This uses the same rule as `../iswc-musicbrainz`: `normalize()` from `../musicbrainz-discogs/normalize.mjs`, plus a Levenshtein allowance of 2 (at most 20% of the longer name).

Search results don't include URL relationships, so unlike the ISWC import, this doesn't check whether the MusicBrainz recording links to a different Wikidata item. `build-batch.mjs` still runs that check if `mb-recordings.tsv` has a `wikidata` column. Recordings whose MusicBrainz entry has no ISRC are only counted in the summary.
