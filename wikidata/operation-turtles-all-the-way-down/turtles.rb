# https://en.wikipedia.org/wiki/Turtles_all_the_way_down
#
# This is a scratch workspace for trying to solve the problem of anime and
# manga on Wikidata not being made up of distinct items.
#
# There are SO MANY items on Wikidata with this problem, it'd be unrealistic
# to solve them manually in any reasonable timeframe. So, automation it is...
#
# For example, all of the following items are listed as both an anime and a manga in the same item:
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

# SPARL Query for getting all items on Wikidata that are both a "manga series"
# and "anime television series". This returns around 800 items. We'll need a
# second query to also get those listed as both a manga and an "anime film".
SPARQL_QUERY = <<~SPARQL
  SELECT DISTINCT ?item ?itemLabel WHERE {
    SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE]". }
    {
      SELECT DISTINCT ?item WHERE {
        ?item p:P31 ?statement0.
        ?statement0 (ps:P31/(wdt:P279*)) wd:Q21198342.
        ?item p:P31 ?statement1.
        ?statement1 (ps:P31/(wdt:P279*)) wd:Q63952888.
      }
    }
  }
SPARQL

ANIME_SPECIFIC_PROPERTIES = [
  'P1811', # list of episodes
  'P1113', # number of episodes
  'P2437', # number of seasons
  'P364', # original language of film or TV show
  'P449', # original broadcaster
  'P2047', # duration
  'P86', # composer
  'P57', # director
  'P725', # voice actor

  'P4086', # MyAnimeList anime ID
  'P8729', # AniList anime ID
  'P1985', # Anime News Network anime ID
  'P5845', # AnimeClick anime ID
  'P1874', # Netflix ID
  'P1267', # AlloCiné series ID
  'P4110', # Crunchyroll ID
  'P4983', # TMDb TV series ID
  'P3138', # OFDb film ID
  'P2603', # Kinopoisk film ID
  'P6992', # IMFDB ID
  'P345', # IMDb ID
  'P480', # FilmAffinity ID
  'P5646', # AniDB anime ID
  'P2603', # Kinopoisk film ID
  'P3138', # OFDb film ID
  'P4835', # TheTVDB.com series ID
  'P5327', # fernsehserien.de ID
  'P5032', # Filmweb.pl film ID
  'P7107', # LezWatch.TV show ID
  'P4834', # Deutsche Synchronkartei series ID
  'P5387', # Behind The Voice Actors TV show ID
  'P4529', # Douban film ID
  'P6127', # Letterboxd film ID
  'P4947', # TMDb movie ID
  'P5925', # Moviepilot.de series ID
].freeze

MANGA_SPECIFIC_PROPERTIES = [
  'P4087', # MyAnimeList manga ID
  'P8731', # AniList manga ID
  'P1984', # Anime News Network manga ID
  'P5849', # AnimeClick manga ID
  'P6947', # Goodreads series ID
].freeze

SHARED_PROPERTIES = [
  'P407', # language of work or name
  'P495', # country of origin
  'P8345', # media franchise
  'P136', # genre
  'P2360', # intended public
  'P921', # main subject
  'P1881', # list of characters
].freeze
