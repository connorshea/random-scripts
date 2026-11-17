# PCGamingWiki

Scripts that add PCGamingWiki IDs (P6337) to Wikidata, by matching PCGamingWiki articles to items through their Steam application IDs (P1733).

Nothing here edits Wikidata. The batch is for you to review and run in QuickStatements. The older scripts, which scraped XML exports and edited Wikidata directly, are in `deprecated/`. The scripts in `export/` call PCGamingWiki's Cargo API without logging in, which it no longer allows.

## Steps

Run these from this folder. Output goes to `data/`. `.json`, `.jsonl` and `.tsv` files are gitignored.

1. `PCGW_USERNAME=... PCGW_PASSWORD=... ruby pcgw_dump.rb` downloads PCGamingWiki's Cargo `Game` table (one row per game article: page name and ID, Steam and GOG IDs, developers, publishers, release dates, series, Wikipedia and StrategyWiki) into `data/pcgw_games.jsonl`. If it's interrupted, run it again to resume.

   Since August 2026, PCGamingWiki only allows Cargo queries from logged-in users, so it needs a bot password from [Special:BotPasswords](https://www.pcgamingwiki.com/wiki/Special:BotPasswords) (the username looks like `YourName@dumper`). Cargo returns 500 rows a request, so a full download is about 115 requests. PCGamingWiki allows 60 requests a minute and blocks the IP for 60 seconds past that, so the dumper waits 1.5 seconds between requests (set `PCGW_REQUEST_INTERVAL` to change it), and waits 65 seconds after a 429.

2. Pull the Wikidata data from QLever:

   ```sh
   for q in ids names; do
     curl -sS --compressed https://qlever.dev/api/wikidata -H 'Accept: text/tab-separated-values' \
       --data-urlencode "query@wd-pcgw-$q.rq" -o data/wd-pcgw-$q.tsv
   done
   ```

   `wd-pcgw-ids.rq` returns every PCGamingWiki ID of any rank, and every non-deprecated Steam ID, with its item. `wd-pcgw-names.rq` returns the English and `mul` labels and aliases of the items with a Steam ID and no PCGamingWiki ID.

   If QLever is busy, it either returns a JSON error instead of a TSV, or appends an error message to a truncated result. The generator stops on both. Run the query again.

3. `ruby pcgw_quickstatements.rb data/wd-pcgw-ids.tsv data/wd-pcgw-names.tsv` writes:

   - `data/pcgw-ids.qs.tsv`: the batch, in the tab-separated (v1) QuickStatements syntax.
   - `data/pcgw-ids-review.tsv`: candidates whose names don't match. Each row has its QuickStatements command, with `|` in place of tabs, so approved rows can be pasted into QuickStatements.
   - `data/pcgw-ids-skipped.tsv`: every other candidate that wasn't added, and why.

The ID is the article's page name with underscores for spaces. Each statement gets the article's MediaWiki page ID (P9675) as a qualifier, like almost every existing PCGamingWiki ID, and is referenced with stated in (P248) PCGamingWiki (Q17013880) and retrieved (P813) set to the day the dump was downloaded:

```
Q193581	P6337	"Half-Life_2"	P9675	"94"	S248	Q17013880	S813	+2026-11-16T00:00:00Z/11
```

## Matching rules

An item gets a PCGamingWiki ID only when:

- the item has no PCGamingWiki ID yet, of any rank
- its Steam IDs lead to exactly one PCGamingWiki article
- none of that article's Steam IDs lead to a different item, and no other article lists the same Steam ID
- the ID isn't already on another item, and no other item in the batch would get it

Candidates go to the review file when none of the item's English or `mul` labels or aliases match the article's name, with or without a trailing disambiguator like " (2016)". Names are compared the same way as in the IGDB scripts (see `../igdb/game_names.rb`).
