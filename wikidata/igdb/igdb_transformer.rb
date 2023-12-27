# frozen_string_literal: true

# Given a JSON file for all IGDB games, it transforms the
# igdb_games.json into a better format for OpenRefine to
# consume.
#
# You should also get a JSON file from the Wikidata Query Service using this query:
#
# SELECT ?item ?igdbId WHERE {
#  ?item wdt:P31 wd:Q7889; # instance of video game
#  wdt:P5794 ?igdbId. # items with an IGDB ID.
# }
#
# Name the file `wikidata-query.json` and place it in the same directory as this script.

require 'json'

# Open igdb_games.json
igdb_games = JSON.parse(File.read('./igdb_games.json'))
wikidata_igdb_items = JSON.parse(File.read('./wikidata-query.json'))
wikidata_igdb_items.sort_by! { |item| item['igdbId'] }

puts igdb_games.length
puts wikidata_igdb_items.length

# Remove category
igdb_games.map! do |igdb_game|
  # Remove category
  igdb_game.delete('category')
  # Remove URL
  igdb_game.delete('url')
  # Remove external_games.id
  igdb_game['external_games'].map! { |ext_game| ext_game.delete('id'); ext_game }
  # Remove websites.id
  igdb_game['websites'].map! { |website| website.delete('id'); website }

  # Remove websites of category 4 (Facebook)
  # Remove websites of category 5 (Twitter)
  # Remove websites of category 6 (Twitch)
  # Remove websites of category 8 (Instagram)
  # Remove websites of category 9 (YouTube)
  # Remove websites of category 13 (Steam), represented by external games already
  # Remove websites of category 14 (Reddit)
  # Remove websites of category 18 (Discord)
  igdb_game['websites'].reject! { |website| [4, 5, 6, 8, 9, 13, 14, 18].include?(website['category']) }

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

  igdb_game['wikidata_id'] = nil

  igdb_game
end

igdb_games.map! do |igdb_game|
  # Add Wikidata IDs to records.
  # Use a binary search because otherwise this takes forever.
  igdb_game['wikidata_id'] = wikidata_igdb_items.bsearch { |item| igdb_game['slug'] <=> item['igdbId'] }&.dig('item')&.sub('http://www.wikidata.org/entity/', '')
  igdb_game
end

# TODO: Convert first release date to an actual date?

File.write('./igdb_games-transformed.json', JSON.pretty_generate({ games: igdb_games }))
