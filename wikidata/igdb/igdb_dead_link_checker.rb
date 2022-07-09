# frozen_string_literal: true

##
# USAGE:
#
# This script uses igdb_games.json to check Wikidata's IGDB IDs and detect invalid/deleted IGDB IDs.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
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

# Query for finding all IGDB IDs.
def query
  return <<-SPARQL
    SELECT ?item ?itemLabel ?igdbId WHERE {
      ?item wdt:P31 wd:Q7889; # instance of video game
                wdt:#{IGDB_GAME_PID} ?igdbId. # items with an IGDB ID.
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,en". }
    }
  SPARQL
end

def wikidata_rows
  sparql_endpoint = "https://query.wikidata.org/sparql"

  client = SPARQL::Client.new(
    sparql_endpoint,
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 3.0" }
  )

  rows = client.query(query)
  rows.map(&:to_h).map do |key_hash|
    {
      name: key_hash[:itemLabel].to_s,
      wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/Q', ''),
      igdb_id: key_hash[:igdbId].to_s
    }
  end
end

puts "Reading data from igdb_games.json."

igdb_games = JSON.load(File.open(File.join(File.dirname(__FILE__), 'igdb_games.json'))).map do |game|
  game.transform_keys(&:to_sym)
end

puts "#{igdb_games.count} games on IGDB."

wikidata_items = wikidata_rows

progress_bar = ProgressBar.create(
  total: wikidata_items.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

wikidata_items_with_dead_igdb_ids = []
# Get an array of every valid IGDB slug from the IGDB dump.
igdb_slugs = igdb_games.map { |igdb_game| igdb_game[:slug] }
puts igdb_slugs.inspect

wikidata_items.each do |wikidata_item|
  if igdb_slugs.include?(wikidata_item[:igdb_id])
    progress_bar.log "IGDB ID '#{wikidata_item[:igdb_id]}' found in dump."
  else
    progress_bar.log "IGDB ID '#{wikidata_item[:igdb_id]}' on Q#{wikidata_item[:wikidata_id]} not found in IGDB dump."
    wikidata_items_with_dead_igdb_ids << wikidata_item
  end
  progress_bar.increment
end

progress_bar.finish unless progress_bar.finished?
puts "Script complete, dumping a JSON blob of Wikidata items with dead IGDB IDs..."

puts JSON.pretty_generate(wikidata_items_with_dead_igdb_ids)
