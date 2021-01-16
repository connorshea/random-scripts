# frozen_string_literal: true

##
# USAGE:
#
# This script uses igdb_games.json to add IGDB numeric game IDs as qualifiers to all IGDB game IDs.
#
# ENVIRONMENT VARIABLES:
#
# WIKIDATA_USERNAME: username for Wikidata account
# WIKIDATA_PASSWORD: password for Wikidata account

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'json'
require 'sparql/client'
require_relative '../wikidata_helper.rb'

include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

IGDB_GAME_PID = 'P5794'
IGDB_NUMERIC_GAME_PID = 'P9043'

# TODO: Write a query for finding all IGDB IDs without the numeric qualifier.
def query
  return <<-SPARQL
    SELECT ?item ?itemLabel ?malId WHERE
    {
      VALUES ?animeTypes {
        wd:Q20650540 # anime film
      }
      ?item wdt:P31 ?animeTypes;
            wdt:#{MAL_ANIME_PID} ?malId. # with a MAL ID
      FILTER NOT EXISTS { ?item wdt:#{ANILIST_ANIME_PID} ?anilistId . } # and no AniList ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL
end

def get_wikidata_items_with_no_igdb_numeric_id_from_sparql
  sparql_endpoint = "https://query.wikidata.org/sparql"

  client = SPARQL::Client.new(
    sparql_endpoint,
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 2.6" }
  )

  rows = client.query(query)

  return rows
end

puts "Reading data from igdb_games.json."

igdb_games = JSON.load(File.open(File.join(File.dirname(__FILE__), 'igdb_games.json'))).map do |game|
  game.transform_keys(&:to_sym)
end

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

puts "#{igdb_games.count} games on IGDB."

wikidata_rows = get_wikidata_items_with_no_igdb_numeric_id_from_sparql

wikidata_items = []

wikidata_rows.each do |row|
  key_hash = row.to_h
  wikidata_item = {
    name: key_hash[:itemLabel].to_s,
    wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/Q', '')
  }

  wikidata_items << wikidata_item
end
