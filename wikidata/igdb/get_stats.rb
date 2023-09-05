require 'json'

# Open igdb_games.json
igdb_games = JSON.parse(File.read('./igdb_games.json'))

puts "Total games: #{igdb_games.count}"
igdb_games = igdb_games.select { |game| game['category'] == 0 }
puts "Total main games: #{igdb_games.count}"

# Filter out games that don't have any external games.
igdb_games = igdb_games.select { |game| game['external_games'].length > 0 }

puts "Total games with external game entries: #{igdb_games.count}"
# Filter out games that don't have any external games from Steam.
igdb_games = igdb_games.select { |game| game['external_games'].map { |external_game| external_game['category'] }.include?(1) }

puts "Total games with Steam entries: #{igdb_games.count}"

igdb_games = igdb_games.select { |game| game['first_release_date'] != nil }
puts "Total games with Steam entries and a release date: #{igdb_games.count}"

puts igdb_games.map { |game| game['external_games'].select { |external_game| external_game['category'] == 1 }.map { |external_game| external_game['url'] } }.flatten.uniq.count
