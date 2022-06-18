#####
# Use the IGDB dump to get Steam IDs for games and then use that information to
# match IGDB IDs to Wikidata items that already have a Steam ID.
#####

require 'json'
require 'debug'

# Pull the Steam ID out of a Steam URL.
#
# Supports the following formats:
# - 'https://store.steampowered.com/app/1418570/Zen_Trails'
# - 'https://store.steampowered.com/app/1281600'
#
# @param url [String]
# @returns [Integer, nil] Will return the Steam ID, or nil if no match was found in the URL (usually this means the URL was malformed).
def steam_id_from_url(url)
  url.slice!('https://store.steampowered.com/app/')
  m = url.match(/(\d+)\/?/)
  return nil if m.nil?
  m.captures.first.to_i
end

igdb_games = JSON.load(File.open(File.join(File.dirname(__FILE__), 'igdb_games.json'))).map do |game|
  game.transform_keys(&:to_sym)
end

puts "#{igdb_games.count} games!"

# Go over every IGDB Game in the JSON blob and add Steam IDs to the hashes
# so we can match them to Wikidata.
igdb_games.map! do |igdb_game|
  # Pull the Steam IDs from the game records, if there are any.
  external_games = igdb_game[:external_games].filter { |ext_game| ext_game['category'] == 1 }.map { |ext_game| ext_game['url'] }.compact
  websites = igdb_game[:websites].filter { |website| website['category'] == 13 }.map { |website| website['url'] }.compact
  # Set Steam IDs on the given IGDB hash.
  igdb_game[:steam_ids] = external_games.concat(websites).uniq.map { |url| steam_id_from_url(url) }
  igdb_game
end

# Filter down to only the IGDB games that have Steam IDs.
igdb_games.filter! { |igdb_game| igdb_game[:steam_ids].count > 0 }
