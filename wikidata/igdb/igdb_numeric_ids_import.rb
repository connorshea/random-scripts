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
  gem 'nokogiri'
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

# Query for finding all IGDB IDs without the numeric qualifier.
def query
  return <<-SPARQL
    SELECT ?item ?itemLabel ?igdbId ?numericId WHERE {
      OPTIONAL {
        ?item p:#{IGDB_GAME_PID} ?statement. # Get the statement of the IGDB ID
        ?statement ps:#{IGDB_GAME_PID} ?igdbId. # Get the actual ID
        FILTER(NOT EXISTS { ?statement pq:#{IGDB_NUMERIC_GAME_PID} ?numericId. }) # Get rid of anything with a numeric IGDB ID qualifier.
      }
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,en". }
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
    wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/Q', ''),
    igdb_id: key_hash[:igdbId].to_s
  }

  wikidata_items << wikidata_item
end

progress_bar = ProgressBar.create(
  total: wikidata_items.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

wikidata_items.each do |wikidata_item|
  igdb_id = wikidata_item[:igdb_id]

  # Find the numeric IGDB ID associated with the Wikidata item's IGDB ID.
  igdb_game = igdb_games.find { |igdb_game| igdb_game[:slug] == igdb_id }
  
  if igdb_game.nil?
    progress_bar.log 'No IGDB numeric ID could be derived from the IGDB ID.'
    progress_bar.increment
    next
  end

  igdb_numeric_id = igdb_game[:id]

  igdb_claims = WikidataHelper.get_claims(entity: "Q#{wikidata_item[:wikidata_id]}", property: IGDB_GAME_PID).dig(IGDB_GAME_PID)
  # Simplify the claims just to the parts we care about: the IGDB slug and the claim ID.
  igdb_claims.map! do |claim|
    {
      claim_id: claim.dig('id'),
      igdb_slug: claim.dig('mainsnak', 'datavalue', 'value')
    }
  end

  # Filter to the claim specifically about the given IGDB slug, in case
  # there are multiple on the same game item.
  igdb_claim_id = igdb_claims.find { |claim| claim[:igdb_slug] == igdb_game[:slug] }&.dig(:claim_id)

  if igdb_claim_id.nil?
    progress_bar.log 'No relevant claim ID could be found.'
    progress_bar.increment
    next
  end

  sleep 1
  progress_bar.log "--------------------------"
  progress_bar.log "Wikidata ID: Q#{wikidata_item[:wikidata_id]}"
  progress_bar.log "IGDB Numeric ID: #{igdb_numeric_id}"
  progress_bar.log "IGDB Slug: #{igdb_game[:slug]}"

  begin
    wikidata_client.set_qualifier(igdb_claim_id.to_s, 'value', IGDB_NUMERIC_GAME_PID, igdb_numeric_id.to_s.to_json)
  rescue => error
    progress_bar.log "ERROR: #{error}"
  end
  progress_bar.increment
end
