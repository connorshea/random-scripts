# frozen_string_literal: true

# Given a JSON file for all IGDB games, it transforms the
# igdb_games.json into a better format for OpenRefine to
# consume. Also pulls some extra data about the GiantBomb
# ID and such, from Wikidata.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'sparql-client'
  gem 'nokogiri'
end

require 'json'
require 'sparql/client'

# Query for finding all items with IGDB IDs.
def igdb_query
  return <<-SPARQL
    SELECT ?item ?igdbId WHERE {
      ?item wdt:P31 wd:Q7889; # instance of video game
      wdt:P5794 ?igdbId. # items with an IGDB ID.
    }
  SPARQL
end

# Query for finding all items with GiantBomb IDs.
def giantbomb_query
  return <<-SPARQL
    SELECT ?item ?itemLabel (SAMPLE(?gbId) as ?gbId) WHERE {
      ?item wdt:P31 wd:Q7889; # instance of video game
      wdt:P5247 ?gbId. # items with a GiantBomb ID.
      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE],en". }
    }
    GROUP BY ?item ?itemLabel
  SPARQL
end

def get_wikidata_items(query)
  sparql_endpoint = "https://query.wikidata.org/sparql"

  client = SPARQL::Client.new(
    sparql_endpoint,
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
  )

  rows = client.query(query)

  return rows
end

# Open igdb_games.json
igdb_games = JSON.parse(File.read('./igdb_games.json'))
wikidata_igdb_items = get_wikidata_items(igdb_query).map(&:to_h).map { |row| { 'item' => row[:item].to_s, 'igdbId' => row[:igdbId].to_s } }
wikidata_igdb_items.sort_by! { |item| item['igdbId'] }
wikidata_giantbomb_items = get_wikidata_items(giantbomb_query).map(&:to_h).map { |row| { 'item' => row[:item].to_s.sub('http://www.wikidata.org/entity/', ''), 'itemLabel' => row[:itemLabel].to_s, 'gbId' => row[:gbId].to_s } }
wikidata_giantbomb_items.sort_by! { |item| item['item'] }

puts igdb_games.length
puts wikidata_igdb_items.length
puts wikidata_giantbomb_items.length

# Remove category
igdb_games.map! do |igdb_game|
  # Remove category
  igdb_game.delete('category')
  # Remove URL
  igdb_game.delete('url')
  # # Remove external_games.id
  # igdb_game['external_games'].map! { |ext_game| ext_game.delete('id'); ext_game }
  # # Remove websites.id
  # igdb_game['websites'].map! { |website| website.delete('id'); website }

  # Remove websites of category 4 (Facebook)
  # Remove websites of category 5 (Twitter)
  # Remove websites of category 6 (Twitch)
  # Remove websites of category 8 (Instagram)
  # Remove websites of category 9 (YouTube)
  # Remove websites of category 13 (Steam), represented by external games already
  # Remove websites of category 14 (Reddit)
  # Remove websites of category 18 (Discord)
  # igdb_game['websites'].reject! { |website| [4, 5, 6, 8, 9, 13, 14, 18].include?(website['category']) }

  ext_game_categories = igdb_game['external_games'].map { |ext_game| ext_game['category'] }
  
  # Extract Steam from external games into its own thing (category 1)
  igdb_game['steam_id'] = nil
  if ext_game_categories.include?(1)
    igdb_game['steam_id'] = igdb_game['external_games'].find { |ext_game| ext_game['category'] == 1 }.dig('uid')&.to_i
  end

  # Extract GiantBomb from external games into its own thing (category 3)
  igdb_game['giantbomb_id'] = nil
  if ext_game_categories.include?(3)
    igdb_game['giantbomb_id'] = igdb_game['external_games'].find { |ext_game| ext_game['category'] == 3 }.dig('url')
    m = igdb_game['giantbomb_id'].match(/https\:\/\/www\.giantbomb\.com\/games\/(\d+\-\d+)\/?/)
    igdb_game['giantbomb_id'] = nil if m.nil?
    igdb_game['giantbomb_id'] = m.captures.first
  end

  # Extract GOG from external games into its own thing (category 5)
  igdb_game['gog_id'] = nil
  if ext_game_categories.include?(5)
    igdb_game['gog_id'] = igdb_game['external_games'].find { |ext_game| ext_game['category'] == 5 }.dig('url')
  end

  # Remove Steam from external games after spliting it out (category 1)
  # Remove GiantBomb from external games after spliting it out (category 3)
  # Remove GOG from external games after spliting it out (category 5)
  # Remove Twitch from external games (category 14)
  igdb_game['external_games'].reject! { |ext_game| [1, 3, 5, 14].include?(ext_game['category']) }

  # Remove all of these as they're not particularly useful for OpenRefine.
  igdb_game.delete('external_games')
  igdb_game.delete('websites')
  igdb_game.delete('platforms')
  igdb_game.delete('involved_companies')
  igdb_game.delete('status')

  # Convert first_release_date integer to an actual date
  igdb_game['first_release_date'] = Time.at(igdb_game['first_release_date'].to_i).to_datetime.strftime('%Y-%m-%d') unless igdb_game['first_release_date'].nil?

  igdb_game['wikidata_id'] = nil
  igdb_game['giantbomb_id_from_wikidata'] = nil

  igdb_game
end

igdb_games.map! do |igdb_game|
  # Add Wikidata IDs to records.
  # Use a binary search because otherwise this takes forever.
  igdb_game['wikidata_id'] = wikidata_igdb_items.bsearch { |item| igdb_game['slug'] <=> item['igdbId'] }&.dig('item')&.sub('http://www.wikidata.org/entity/', '')
  igdb_game
end

igdb_games.map! do |igdb_game|
  unless igdb_game['wikidata_id'].nil?
    # Add GiantBomb IDs from Wikidata to records.
    # Use a binary search because otherwise this takes forever.
    igdb_game['giantbomb_id_from_wikidata'] = wikidata_giantbomb_items.bsearch { |item| igdb_game['wikidata_id'] <=> item['item'] }&.dig('gbId')
  end
  igdb_game
end

File.write('./igdb_games-transformed.json', JSON.pretty_generate({ games: igdb_games }))
