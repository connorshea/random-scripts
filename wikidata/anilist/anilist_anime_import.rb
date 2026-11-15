# frozen_string_literal: true

##
# USAGE:
#
# This script pulls down every anime from AniList and then - based on their MAL IDs - will update their Wikidata items with the AniList ID, if it exists.
#
# ENVIRONMENT VARIABLES:
#
# USE_ANILIST_API (optional): download a fresh copy of every anime from the AniList API first (or resume an interrupted download). Otherwise the existing dump in data/ is used, see anilist_dump.rb.
# WIKIDATA_USERNAME: username for Wikidata account
# WIKIDATA_PASSWORD: password for Wikidata account

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.13'
end

require 'json'
require 'sparql/client'
require_relative '../wikidata_helper.rb'
require_relative '../wikidata_bot_client.rb'
require_relative './anilist_api.rb'

include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

ANILIST_ANIME_PID = 'P8729'
MAL_ANIME_PID = 'P4086'

def query
  return <<-SPARQL
    SELECT ?item ?itemLabel ?malId WHERE
    {
      VALUES ?animeTypes {
        wd:Q20650540 # anime film
        wd:Q11424 # film
        wd:Q1107 # anime
        wd:Q100269041 # anime television series season
        wd:Q3464665 # television series season
        wd:Q63952888 # anime television series
        wd:Q220898 # OVA
      }
      ?item wdt:P31 ?animeTypes;
            wdt:#{MAL_ANIME_PID} ?malId. # with a MAL ID
      FILTER NOT EXISTS { ?item wdt:#{ANILIST_ANIME_PID} ?anilistId . } # and no AniList ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL
end

def get_wikidata_items_with_no_anilist_id_from_sparql
  client = SPARQL::Client.new(
    "https://query.wikidata.org/sparql",
    method: :get,
    headers: { 'User-Agent': WikidataHelper::USER_AGENT }
  )

  client.query(query)
end

# Only entries with a MAL ID can be matched.
anilist_anime = AniListAPI.load('ANIME').reject { |anime| anime['idMal'].nil? }

puts "#{anilist_anime.count} anime with MAL IDs on AniList"

# Index the Wikidata items by MAL ID. If several items share a MAL ID, only
# the first one is used.
wikidata_items_by_mal_id = {}
get_wikidata_items_with_no_anilist_id_from_sparql.each do |row|
  wikidata_items_by_mal_id[row[:malId].to_s] ||= {
    name: row[:itemLabel].to_s,
    wikidata_id: row[:item].to_s.sub('http://www.wikidata.org/entity/', '')
  }
end

# Pair up each AniList anime with the Wikidata item that has its MAL ID and no
# AniList ID.
matches = anilist_anime.filter_map do |anime|
  item = wikidata_items_by_mal_id[anime['idMal'].to_s]
  [anime, item] unless item.nil?
end

puts "#{matches.count} anime can be matched based on MAL IDs."
exit if matches.empty?

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

progress_bar = ProgressBar.create(
  total: matches.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

anime_matched = 0

matches.each do |anime, item|
  # Make sure the anime doesn't already have a AniList ID, the SPARQL results
  # may be stale.
  existing_claims = WikidataHelper.get_claims(entity: item[:wikidata_id], property: ANILIST_ANIME_PID)
  if existing_claims != {} && !existing_claims.nil?
    progress_bar.log "#{item[:wikidata_id]} already has a AniList anime ID."
    progress_bar.increment
    next
  end

  begin
    wikidata_client.create_claim(item[:wikidata_id], "value", ANILIST_ANIME_PID, "\"#{anime['id']}\"")
    anime_matched += 1
    progress_bar.log "Updated #{item[:wikidata_id]} (#{item[:name]}) with AniList ID of #{anime['id']}."
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
  end
  sleep 1

  progress_bar.increment
end

puts "#{anime_matched} anime matched based on MAL ID."

progress_bar.finish unless progress_bar.finished?
