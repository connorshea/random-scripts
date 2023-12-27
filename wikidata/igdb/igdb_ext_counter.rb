require 'debug'
require 'json'

# Open igdb_games.json
igdb_games = JSON.parse(File.read('./igdb_games.json'))

epic_count = igdb_games.filter { |game| game['external_games'].map { |ext| ext['category'] }.include?(26) }.length
gog_count = igdb_games.filter { |game| game['external_games'].map { |ext| ext['category'] }.include?(5) }.length
puts "Epic Games Store: #{epic_count}" # Currently Wikidata has 1321 items with an Epic Games Store ID and IGDB ID.
puts "GOG.com: #{gog_count}" # Currently Wikidata has 3729 items with a GOG.com ID and IGDB ID.
