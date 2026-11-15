# frozen_string_literal: true

##
# USAGE:
#
# This script pulls down every manga from AniList and then - based on their MAL IDs - will update their Wikidata items with the AniList ID, if it exists.
#
# ENVIRONMENT VARIABLES:
#
# USE_ANILIST_API (optional): download a fresh copy of every manga from the AniList API first (or resume an interrupted download). Otherwise the existing dump in data/ is used, see anilist_dump.rb.
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

ANILIST_MANGA_PID = 'P8731'
MAL_MANGA_PID = 'P4087'

def query
  return <<-SPARQL
    SELECT ?item ?itemLabel ?malId WHERE
    {
      VALUES ?mangaTypes {
        wd:Q21198342 # manga series
        wd:Q747381 # light novel
        wd:Q74262765 # manhwa series
        wd:Q1667921 # novel series
      }
      ?item wdt:P31 ?mangaTypes;
            wdt:#{MAL_MANGA_PID} ?malId. # with a MAL ID
      FILTER NOT EXISTS { ?item wdt:#{ANILIST_MANGA_PID} ?anilistId . } # and no AniList ID
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
anilist_manga = AniListAPI.load('MANGA').reject { |manga| manga['idMal'].nil? }

puts "#{anilist_manga.count} manga with MAL IDs on AniList"

# Index the Wikidata items by MAL ID. If several items share a MAL ID, only
# the first one is used.
wikidata_items_by_mal_id = {}
get_wikidata_items_with_no_anilist_id_from_sparql.each do |row|
  wikidata_items_by_mal_id[row[:malId].to_s] ||= {
    name: row[:itemLabel].to_s,
    wikidata_id: row[:item].to_s.sub('http://www.wikidata.org/entity/', '')
  }
end

# Pair up each AniList manga with the Wikidata item that has its MAL ID and no
# AniList ID.
matches = anilist_manga.filter_map do |manga|
  item = wikidata_items_by_mal_id[manga['idMal'].to_s]
  [manga, item] unless item.nil?
end

puts "#{matches.count} manga can be matched based on MAL IDs."
exit if matches.empty?

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

progress_bar = ProgressBar.create(
  total: matches.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

manga_matched = 0

matches.each do |manga, item|
  # Make sure the manga doesn't already have a AniList ID, the SPARQL results
  # may be stale.
  existing_claims = WikidataHelper.get_claims(entity: item[:wikidata_id], property: ANILIST_MANGA_PID)
  if existing_claims != {} && !existing_claims.nil?
    progress_bar.log "#{item[:wikidata_id]} already has a AniList manga ID."
    progress_bar.increment
    next
  end

  begin
    wikidata_client.create_claim(item[:wikidata_id], "value", ANILIST_MANGA_PID, "\"#{manga['id']}\"")
    manga_matched += 1
    progress_bar.log "Updated #{item[:wikidata_id]} (#{item[:name]}) with AniList ID of #{manga['id']}."
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
  end
  sleep 2

  progress_bar.increment
end

puts "#{manga_matched} manga matched based on MAL ID."

progress_bar.finish unless progress_bar.finished?
