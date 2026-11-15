# IGDB

Scripts that work with a local dump of IGDB (the Internet Game Database) and Wikidata's IGDB game ID (P5794), and with Steam data.

## Steam, Epic Games Store and GOG IDs from IGDB

`igdb_store_ids_quickstatements.rb` generates QuickStatements batches that add these IDs to items with an IGDB game ID, using the store links on the IGDB game:

- Steam application ID (P1733)
- Epic Games Store ID (P6278)
- GOG application ID (P2725)

Steam IDs get a platform (P400) qualifier for each platform Steam lists, and the item gets distributed by (P750) Steam (Q337535), unless it already has it. Items getting an Epic or GOG ID likewise get P750 Epic Games Store (Q59510068) or GOG.com (Q1486288). P750 never gets platform qualifiers, and its reference is just inferred from (P3452) the store, e.g. `S3452 Q337535`.

Nothing here edits Wikidata or calls IGDB. The batches are for you to review and run in QuickStatements.

### Input

- The IGDB dump, `igdb_games.json`, downloaded with `igdb_dumper.rb` (see step 1).
- Every IGDB, Steam, Epic and GOG ID on Wikidata, plus the names of items with an IGDB ID, from QLever (see step 2).
- Steam's full app list (every app ID and name), to check Steam IDs against Steam's own names (see step 3).
- The platforms Steam lists for each candidate Steam app (see step 5).

Output goes to `data/`. `.json` and `.tsv` files are gitignored.

### Steps

Run these from this folder.

1. `ruby igdb_dumper.rb` downloads every game on IGDB into `igdb_games.json`. It needs `TWITCH_CLIENT_ID` and `TWITCH_CLIENT_SECRET`; see https://api-docs.igdb.com/#authentication. Skip this if the dump is recent enough.

2. Pull the Wikidata data from QLever:

   ```sh
   for q in store-ids names; do
     curl -sS --compressed https://qlever.dev/api/wikidata -H 'Accept: text/tab-separated-values' \
       --data-urlencode "query@wd-igdb-$q.rq" -o data/wd-igdb-$q.tsv
   done
   ```

   `wd-igdb-store-ids.rq` returns every non-deprecated P5794 value, and every P1733, P6278 and P2725 value of any rank, with its item. It also returns which Steam ID statements have a platform qualifier, and which items have P750 Steam. `wd-igdb-names.rq` returns the English and `mul` labels and aliases of every item with an IGDB ID. It uses QLever's `@en@rdfs:label` syntax: the same query with `FILTER(LANG(...))` times out.

   If QLever fails while sending a result, it appends an error message to the incomplete file, and curl still exits successfully. The generator checks for that message and stops if it finds it. If it does, run the query again.

3. `STEAM_API_KEY=... ruby steam_app_list_dump.rb` downloads Steam's app list into `data/steam_app_list.jsonl`, using `IStoreService/GetAppList`. It pages through games, DLC and software at 50,000 apps per request, so it takes a few requests. It needs a Steam Web API key (free, from https://steamcommunity.com/dev/apikey), which is only sent to `api.steampowered.com` and isn't logged. Without the app list, the generator writes no Steam statements.

4. `ruby igdb_store_ids_quickstatements.rb data/wd-igdb-store-ids.tsv data/wd-igdb-names.tsv` writes:

   - `data/igdb-steam-ids.qs.tsv`, `data/igdb-epic-ids.qs.tsv`, `data/igdb-gog-ids.qs.tsv`: the batches, in the tab-separated (v1) QuickStatements syntax.
   - `data/igdb-store-ids-name-mismatches.tsv`: candidates to review, with the reason. Each row has its QuickStatements command, so approved rows can be copied into a batch.
   - `data/igdb-store-ids-skipped.tsv`: every other candidate that wasn't added, and why.
   - `data/igdb-steam-qualifiers.qs.tsv`: for items that already have the Steam ID IGDB links to, the platform qualifiers and P750 Steam they're missing. This also finishes a Steam batch that was only partly run.
   - `data/igdb-steam-ids-to-check.txt`: Steam app IDs whose platforms haven't been fetched. Steam candidates without platforms are skipped until step 5 is done.

5. `ruby steam_platforms_fetch.rb` fetches the platforms for the app IDs in `data/igdb-steam-ids-to-check.txt` into `data/steam_platforms.jsonl`, from Steam's `IStoreBrowseService/GetItems`, 100 apps per request. Only apps that aren't cached are fetched. `STEAM_API_KEY` is sent if it's set, but isn't required. Then run step 4 again.

In the review file, a row with several commands joins them with `||`, which QuickStatements reads as a line break.

Each ID statement gets a reference: stated in (P248) IGDB (Q20056333), the IGDB game ID it came from, and retrieved (P813) set to the day the dump was downloaded:

```
Q117809	P1733	"475100"	S248	Q20056333	S5794	"kalonline"	S813	+2026-11-14T00:00:00Z/11
```

### Where the IDs come from

| Store | IGDB external game source | IGDB website type | Value |
|---|---|---|---|
| Steam | 1 (uid and URL) | 13 | App ID, e.g. `211740` |
| Epic Games Store | 26 (URL) | 16 | Product slug from `/p/<slug>`, e.g. `thief-5bb95f` |
| GOG | 5 (URL) | 17 | `game/<slug>` from `/game/<slug>`, e.g. `game/thief_3` |

For Epic and GOG, IGDB's `uid` is an internal store ID, not the slug Wikidata uses, so those values come from the URLs. The GOG product ID property (P12727) isn't filled in.

### Matching rules

An item gets a store's ID only when:

- the item has no ID for that store yet, of any rank
- every IGDB ID on the item is in the dump, and together they link to exactly one ID for that store
- no other IGDB game links to that store ID. Shared IDs usually mean editions, bundles or DLC.
- the store ID isn't already on another item, and no other item in the batch would get it
- the ID matches the property's format constraint
- one of the item's English or `mul` labels or aliases matches the IGDB game's name
- for Epic and GOG, the store slug resembles the IGDB game's slug or name
- for Steam, Steam lists at least one platform for the app
- for Steam, the app ID is in Steam's app list, and Steam's name for it matches the IGDB name or one of the item's names. This catches IGDB linking a game to the wrong app, including its soundtrack, demo or a DLC, whose names differ.

The last three rules send candidates to the review file rather than skipping them.

Names are compared after removing ™, ® and ©, NFKC normalization, lowercasing, removing a trailing "(video game)", treating "&" as "and", and removing everything that isn't a letter or digit. Names of 8 or more characters also match within a Levenshtein distance of 2, if their lengths differ by no more than 2.

The slug check catches IGDB linking a game to a bundle (`cossacks_ii_anthology` for Cossacks II) or to an unrelated product. A slug resembles the game when, after removing Epic's 6-character hex suffix and all punctuation, it contains the IGDB slug or name, is contained in it, or is within a Levenshtein distance of 2. Some correct links fail this, like `silent-hunter-3` for Silent Hunter III, so check the review file.

## Platforms from Steam IDs

`steam_platforms_quickstatements.rb` generates a QuickStatements batch that adds platform (P400) statements to video games that have a Steam application ID (P1733) but no platform statement. The platforms come from what Steam lists for the app, so they're only ever Windows (Q1406), macOS (Q14116) and Linux (Q388).

### Steps

Run these from this folder.

1. Pull the items from QLever:

   ```sh
   curl -sS --compressed https://qlever.dev/api/wikidata -H 'Accept: text/tab-separated-values' \
     --data-urlencode "query@wd-steam-no-platform.rq" -o data/wd-steam-no-platform.tsv
   ```

   `wd-steam-no-platform.rq` returns every instance of (P31) video game (Q7889) with a non-deprecated Steam ID and no P400 statement of any rank. Items that already have a platform are left alone.

2. `ruby steam_platforms_quickstatements.rb data/wd-steam-no-platform.tsv` writes `data/steam-platforms-ids-to-check.txt`, the Steam IDs whose platforms haven't been fetched yet.

3. `ruby steam_platforms_fetch.rb data/steam-platforms-ids-to-check.txt` fetches them into `data/steam_platforms.jsonl`, the same cache the IGDB store ID generator uses.

4. Run step 2 again. It writes:

   - `data/steam-platforms.qs.tsv`: the batch.
   - `data/steam-platforms-skipped.tsv`: items that weren't added, and why, for example because Steam didn't return the app.

Each statement is referenced with stated in (P248) Steam (Q337535), the Steam ID, and retrieved (P813) set to the day the platforms were fetched:

```
Q10840122	P400	Q1406	S248	Q337535	S1733	"1657240"	S813	+2026-11-15T00:00:00Z/11
```

An item with several Steam IDs gets the platforms of all of them, and each statement is referenced with every Steam ID that lists that platform.
