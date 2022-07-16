# https://en.wikipedia.org/wiki/Turtles_all_the_way_down
#
# This is a scratch workspace for trying to solve the problem of anime and
# manga on Wikidata not being made up of distinct items.
#
# There are SO MANY items on Wikidata with this problem, it'd be unrealistic
# to solve them manually in any reasonable timeframe. So, automation it is...
#
# For example, all of the following items are listed as both an anime and a manga in the same item (as of writing, July 16 2022):
# - https://www.wikidata.org/wiki/Q1477323
# - https://www.wikidata.org/wiki/Q699760
# - https://www.wikidata.org/wiki/Q427448
# - https://www.wikidata.org/wiki/Q1017038
# - https://www.wikidata.org/wiki/Q280619
# - https://www.wikidata.org/wiki/Q715240
# - https://www.wikidata.org/wiki/Q715519
# - https://www.wikidata.org/wiki/Q643266
# - https://www.wikidata.org/wiki/Q1051912 (this is also listed as video game)
# - https://www.wikidata.org/wiki/Q865487
# - https://www.wikidata.org/wiki/Q1742099
# - https://www.wikidata.org/wiki/Q1402696
# - https://www.wikidata.org/wiki/Q2348046
# - https://www.wikidata.org/wiki/Q1191210
# - https://www.wikidata.org/wiki/Q531723

##
# Goal of this script:
# - Grab all the items on Wikidata that are both an anime and a manga.
# - Go through each item one at a time.
#   - Using the lists of properties that are specific to one type (or are relevant to both), split the statements on the item into their own independent manga and anime items.
#   - Create the manga item.
#   - Create the anime item.
#   - Remove the properties that are no longer relevant from the original, shared item.
#   - Change "instance of" on the original shared item to "media franchise".
#   - Manually fix any issues on the three items as-necessary.
#     - For example, publication date.
#   - Continue to the next item.

# SPARL Query for getting all items on Wikidata that are both a "manga series"
# and "anime television series", but not a light novel or video game.
# This returns around 700 items. We might want to modify this to include
# items marked as "anime film" as well.
SPARQL_QUERY = <<~SPARQL.freeze
  SELECT DISTINCT ?item ?itemLabel WHERE {
    SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE]". }
    {
      SELECT DISTINCT ?item WHERE {
        # Items that are both an anime television series and a manga series.
        ?item p:P31 ?statement0.
        ?statement0 ps:P31 wd:Q21198342.
        ?item p:P31 ?statement1.
        ?statement1 ps:P31 wd:Q63952888.
        # Exclude those that are also marked as light novels, to reduce how
        # many complex cases we need to handle.
        MINUS {
          ?item p:P31 ?statement2.
          ?statement2 (ps:P31/(wdt:P279*)) wd:Q747381.
        }
        # Exclude light novel series'
        MINUS {
          ?item p:P31 ?statement3.
          ?statement3 (ps:P31/(wdt:P279*)) wd:Q104213567.
        }
        # Exclude video games
        MINUS {
          ?item p:P31 ?statement4.
          ?statement4 (ps:P31/(wdt:P279*)) wd:Q7889.
        }
      }
    }
  }
SPARQL

ANIME_TELEVISION_SERIES_QID = 'Q63952888'.freeze
MANGA_SERIES_QID = 'Q21198342'.freeze
LIGHT_NOVEL_QID = 'Q747381'.freeze
LIGHT_NOVEL_SERIES_QID = 'Q104213567'.freeze
VIDEO_GAME_QID = 'Q7889'.freeze
INSTANCE_OF_PID = 'P31'.freeze

ANIME_SPECIFIC_PROPERTIES = {
  'list of episodes': 'P1811',
  'number of episodes': 'P1113',
  'number of seasons': 'P2437',
  'original language of film or TV show': 'P364',
  'original broadcaster': 'P449',
  'duration': 'P2047',
  'composer': 'P86',
  'director': 'P57',
  'voice actor': 'P725',
  'discography': 'P358',
  # This one is debatable, but generally speaking you wouldn't have a character
  # designer on a manga, so it should be safe 99% of the time to assume this is
  # anime-specific.
  'character designer': 'P8670',
  # For some reason this has a constraint that prevents it from being used on
  # manga, light novels, and media franchises, so we'll just consider it an
  # anime-only property.
  'intended public': 'P2360',

  'MyAnimeList anime ID': 'P4086',
  'AniList anime ID': 'P8729',
  'Anime News Network anime ID': 'P1985',
  'AnimeClick anime ID': 'P5845',
  'Netflix ID': 'P1874',
  'AlloCiné series ID': 'P1267',
  'Crunchyroll ID': 'P4110',
  'TMDb TV series ID': 'P4983',
  'OFDb film ID': 'P3138',
  'Kinopoisk film ID': 'P2603',
  'IMFDB ID': 'P6992',
  'IMDb ID': 'P345',
  'FilmAffinity ID': 'P480',
  'AniDB anime ID': 'P5646',
  'Kinopoisk film ID': 'P2603',
  'OFDb film ID': 'P3138',
  'TheTVDB.com series ID': 'P4835',
  'fernsehserien.de ID': 'P5327',
  'Filmweb.pl film ID': 'P5032',
  'LezWatch.TV show ID': 'P7107',
  'Deutsche Synchronkartei series ID': 'P4834',
  'Behind The Voice Actors TV show ID': 'P5387',
  'Douban film ID': 'P4529',
  'Letterboxd film ID': 'P6127',
  'TMDb movie ID': 'P4947',
  'Moviepilot.de series ID': 'P5925'
}.freeze

MANGA_SPECIFIC_PROPERTIES = {
  'MyAnimeList manga ID': 'P4087',
  'AniList manga ID': 'P8731',
  'Anime News Network manga ID': 'P1984',
  'AnimeClick manga ID': 'P5849',
  'Goodreads series ID': 'P6947',
}.freeze

SHARED_PROPERTIES = {
  'language of work or name': 'P407',
  'country of origin': 'P495',
  'media franchise': 'P8345',
  'genre': 'P136',
  'main subject': 'P921',
  'list of characters': 'P1881',
}.freeze
