# AniList and MyAnimeList IDs

Scripts that generate QuickStatements batches adding AniList IDs and MyAnimeList (MAL) IDs to Wikidata items that have one but not the other. They cover anime (AniList anime ID P8729, MAL anime ID P4086) and manga (AniList manga ID P8731, MAL manga ID P4087). Matches come from the MAL links in a local dump of AniList. Each one is checked against the Wikidata item's names and against MAL's own titles.

Nothing here edits Wikidata. The batches are for you to review and run in QuickStatements.

## Input

- A dump of every AniList anime or manga, downloaded with `anilist_dump.rb` (see step 1).
- Every AniList and MAL ID on Wikidata, plus the labels and aliases of the items that have only one of them, from QLever (see step 2).
- MAL's titles for the candidates, fetched from Jikan (see step 4).

Everything is written to `data/`. The `.jsonl` and `.tsv` files there are gitignored.

## Steps

Run these from this folder. Replace `manga` with `anime` for anime.

1. `ruby anilist_dump.rb manga` downloads every manga from the AniList GraphQL API into `data/anilist_manga.jsonl`. It takes a while: requests are spaced to the rate limit AniList reports (currently a degraded 30 a minute). While it runs it writes to `data/anilist_manga.jsonl.partial`. If it's interrupted, run the same command again and it resumes where it stopped. The previous dump is only replaced once the new one is complete. Set `ANILIST_REQUEST_INTERVAL` (seconds) to override the request spacing.

2. Pull the Wikidata IDs and names from QLever:

   ```sh
   for q in ids names; do
     curl -s https://qlever.dev/api/wikidata -H 'Accept: text/tab-separated-values' \
       --data-urlencode "query@wd-anilist-mal-manga-$q.rq" -o data/wd-anilist-mal-manga-$q.tsv
   done
   ```

   `wd-anilist-mal-manga-ids.rq` returns every P8731 and P4087 value, of any rank, with its item. `wd-anilist-mal-manga-names.rq` returns the labels and aliases, in every language, of the items that have only one of the two IDs.

3. `ruby anilist_mal_quickstatements.rb manga data/wd-anilist-mal-manga-ids.tsv data/wd-anilist-mal-manga-names.tsv` finds the candidates. It writes the MAL IDs they need checked to `data/anilist-mal-manga-mal-ids-to-check.txt`. The first time, every candidate is skipped because no MAL titles are cached yet.

4. `ruby jikan_fetch.rb manga` fetches MAL's titles for those IDs from Jikan (`https://api.jikan.moe/v4/manga/<id>`, an unofficial MAL API that needs no key). The results go to `data/mal_manga.jsonl`. That file doubles as a cache, so each ID is only fetched once, and an interrupted run can just be started again. It sends one request every 1.25 seconds to stay under Jikan's 60 a minute, so 1,000 IDs take about 20 minutes. If it says some IDs couldn't be fetched, run it again.

5. Run step 3 again. This time it writes the batch.

Steps 3–5 write:

- `data/anilist-mal-manga-ids.qs.tsv`: the QuickStatements batch, in the tab-separated (v1) syntax.
- `data/anilist-mal-manga-name-mismatches.tsv`: candidates whose Wikidata names or MAL titles don't match AniList's titles, for review. Each row has its QuickStatements command, so approved rows can be copied into the batch.
- `data/anilist-mal-manga-skipped.tsv`: every other candidate that wasn't added, and why.

Each statement gets a reference with the ID it was derived from, plus retrieved (P813) set to the day the AniList dump was downloaded. A new MAL ID is referenced with the item's AniList ID, and a new AniList ID with the item's MAL ID:

```
Q91917	P4087	"1515"	S8731	"31515"	S813	+2026-11-15T00:00:00Z/11
```

## Matching rules

For an item with an AniList ID but no MAL ID, the MAL ID of its AniList entry is added. For an item with a MAL ID but no AniList ID, the AniList entry with that MAL ID is added. Either way, only when:

- the AniList entry is in the dump and, for the first case, has a MAL ID
- all of the item's IDs point to the same single candidate. When adding an AniList ID, only one AniList entry may have the item's MAL ID.
- the ID being added isn't already on another item, of any rank, and no other item in the batch would get it too
- one of the item's labels or aliases matches one of the AniList entry's English, romaji or native titles
- one of MAL's titles matches one of the AniList titles or the item's names
- MAL has an entry with that ID (a 404 from Jikan is skipped)
- both IDs match the properties' format constraint, `[1-9]\d*`

Names are compared after NFKC normalization, lowercasing and removing everything that isn't a letter or digit. First-season markers on the Wikidata side ("X, season 1", "X 1st Season", "X 第1期") are ignored. Names of 8 or more characters also match within a Levenshtein distance of 2, if their lengths differ by no more than 2.

## Other scripts

- `anilist_anime_mixnmatch_generator.rb` writes `anilist_anime_mixnmatch.tsv`, a Mix'n'match catalogue of every anime in the dump: ID, title, a short generated description, and a suggested item type.

## API notes

- `anilist_api.rb` and `jikan_api.rb` send a User-Agent naming this repository.
- AniList: see https://docs.anilist.co/guide/rate-limiting. The client paces requests to `X-RateLimit-Limit`, waits for `X-RateLimit-Reset` when `X-RateLimit-Remaining` hits 0, and on a 429 waits for `Retry-After`. AniList won't page past 5,000 results, so the dump walks the ID space in blocks of 2,500 IDs with `id_in`.
- Jikan: 429s wait for `Retry-After`, or 60 seconds. 5xx errors (which Jikan returns when MAL is slow) and timeouts back off with growing waits. An ID is left for the next run after 5 retries.
- Both clients log with timestamps and say when, and for how long, they're waiting beyond the usual spacing.
