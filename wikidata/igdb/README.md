# IGDB

Scripts that work with a local dump of IGDB (the Internet Game Database) and Wikidata's IGDB game ID (P5794).

## Steam, Epic Games Store and GOG IDs from IGDB

`igdb_store_ids_quickstatements.rb` generates QuickStatements batches that add these IDs to items with an IGDB game ID, using the store links on the IGDB game:

- Steam application ID (P1733)
- Epic Games Store ID (P6278)
- GOG application ID (P2725)

Nothing here edits Wikidata or calls IGDB. The batches are for you to review and run in QuickStatements.

### Input

- The IGDB dump, `igdb_games.json`, downloaded with `igdb_dumper.rb` (see step 1).
- Every IGDB, Steam, Epic and GOG ID on Wikidata, plus the names of items with an IGDB ID, from QLever (see step 2).

Output goes to `data/`. `.json` and `.tsv` files are gitignored.

### Steps

Run these from this folder.

1. `ruby igdb_dumper.rb` downloads every game on IGDB into `igdb_games.json`. It needs `TWITCH_CLIENT_ID` and `TWITCH_CLIENT_SECRET`; see https://api-docs.igdb.com/#authentication. Skip this if the dump is recent enough.

2. Pull the Wikidata data from QLever:

   ```sh
   for q in store-ids names; do
     curl -s https://qlever.dev/api/wikidata -H 'Accept: text/tab-separated-values' \
       --data-urlencode "query@wd-igdb-$q.rq" -o data/wd-igdb-$q.tsv
   done
   ```

   `wd-igdb-store-ids.rq` returns every non-deprecated P5794 value, and every P1733, P6278 and P2725 value of any rank, with its item. `wd-igdb-names.rq` returns the English and `mul` labels and aliases of every item with an IGDB ID. It uses QLever's `@en@rdfs:label` syntax: the same query with `FILTER(LANG(...))` times out.

   If QLever fails while sending a result, it appends an error message to the incomplete file, and curl still exits successfully. The generator checks for that message and stops if it finds it. If it does, run the query again.

3. `ruby igdb_store_ids_quickstatements.rb data/wd-igdb-store-ids.tsv data/wd-igdb-names.tsv` writes:

   - `data/igdb-steam-ids.qs.tsv`, `data/igdb-epic-ids.qs.tsv`, `data/igdb-gog-ids.qs.tsv`: the batches, in the tab-separated (v1) QuickStatements syntax.
   - `data/igdb-store-ids-name-mismatches.tsv`: candidates to review, with the reason. Each row has its QuickStatements command, so approved rows can be copied into a batch.
   - `data/igdb-store-ids-skipped.tsv`: every other candidate that wasn't added, and why.

Each statement gets a reference: stated in (P248) IGDB (Q20056333), the IGDB game ID it came from, and retrieved (P813) set to the day the dump was downloaded:

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

The last two rules send candidates to the review file rather than skipping them.

Names are compared after removing ™, ® and ©, NFKC normalization, lowercasing, removing a trailing "(video game)", treating "&" as "and", and removing everything that isn't a letter or digit. Names of 8 or more characters also match within a Levenshtein distance of 2, if their lengths differ by no more than 2.

The slug check catches IGDB linking a game to a bundle (`cossacks_ii_anthology` for Cossacks II) or to an unrelated product. A slug resembles the game when, after removing Epic's 6-character hex suffix and all punctuation, it contains the IGDB slug or name, is contained in it, or is within a Levenshtein distance of 2. Some correct links fail this, like `silent-hunter-3` for Silent Hunter III, so check the review file.
