# Generate a list of games from Wikidata.
require 'json'

games = File.read('pretty_games.json')

games_json = JSON.parse(games)

games_json.map { |game| game["item"].sub!('http://www.wikidata.org/entity/', '') }

puts games_json.length

games_json.uniq! { |game| game["item"] }

puts games_json.length

bad_games = games_json.select { |game| game["item"] == game["itemLabel"] }
good_games = games_json.select { |game| game["item"] != game["itemLabel"] }

puts bad_games.length
puts bad_games.sample(5)

puts good_games.length
puts good_games.sample(5)

puts good_games.sample(100).to_json

File.write('seed_data.json', good_games.sample(100).to_json)
