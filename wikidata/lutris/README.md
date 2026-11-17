# Lutris

Scripts that add Lutris game IDs (P7597) to Wikidata, by matching Lutris games to items through the IGDB game IDs (P5794) and Steam application IDs (P1733) that Lutris links each game to.

Nothing here edits Wikidata. The batch is for you to review and run in QuickStatements. The 2019 script that edited Wikidata directly is in `deprecated/`.

## Steps

Run these from this folder. Output goes to `data/`. `.json`, `.jsonl` and `.tsv` files are gitignored.

1. `ruby lutris_dump.rb` downloads every game from https://lutris.net/api/games into `data/lutris_games.jsonl`. The API returns at most 250 games a page, so a full download is about 1,400 requests, one a second by default (set `LUTRIS_REQUEST_INTERVAL` to change it). If it's interrupted, run it again to resume.

2. Pull the Wikidata data from QLever:

   ```sh
   for q in ids names; do
     curl -sS --compressed https://qlever.dev/api/wikidata -H 'Accept: text/tab-separated-values' \
       --data-urlencode "query@wd-lutris-$q.rq" -o data/wd-lutris-$q.tsv
   done
   ```

   `wd-lutris-ids.rq` returns every Lutris ID of any rank, and every non-deprecated IGDB and Steam ID, with its item. `wd-lutris-names.rq` returns the English and `mul` labels and aliases of the items with an IGDB or Steam ID and no Lutris ID.

   If QLever is busy, it either returns a JSON error instead of a TSV, or appends an error message to a truncated result. The generator stops on both. Run the query again.

3. `ruby lutris_quickstatements.rb data/wd-lutris-ids.tsv data/wd-lutris-names.tsv` writes:

   - `data/lutris-ids.qs.tsv`: the batch, in the tab-separated (v1) QuickStatements syntax.
   - `data/lutris-ids-review.tsv`: candidates to review, with the reason. Each row has its QuickStatements command, with `|` in place of tabs, so approved rows can be pasted into QuickStatements.
   - `data/lutris-ids-skipped.tsv`: every other candidate that wasn't added, and why.

Each statement is referenced with stated in (P248) Lutris (Q75129027) and retrieved (P813) set to the day the dump was downloaded:

```
Q100042	P7597	"blasteroids"	S248	Q75129027	S813	+2026-11-16T00:00:00Z/11
```

## Matching rules

An item gets a Lutris ID only when:

- the item has no Lutris ID yet, of any rank
- its IGDB and Steam IDs together lead to exactly one Lutris game
- none of that Lutris game's IGDB or Steam links lead to a different item, and no other Lutris game links to the same IGDB or Steam ID
- the Lutris slug isn't already on another item, and no other item in the batch would get it
- the slug matches the P7597 format constraint

Candidates go to the review file when none of the item's English or `mul` labels or aliases match the Lutris game's name, its aliases or the names of its IGDB and Steam links, or when the item and the Lutris game both have IGDB (or Steam) IDs but don't share one. Names are compared the same way as in the IGDB scripts (see `../igdb/game_names.rb`).

Lutris games with `change_for` set are pending edits to another game, and are ignored.
