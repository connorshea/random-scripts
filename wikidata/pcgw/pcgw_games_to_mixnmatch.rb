# Takes the pcgw_games_list.json file and outputs a tab-delimited file for mix'n'match.
require 'open-uri'
require 'json'

games_list = JSON.parse(File.read('pcgw_games_list.json'))

games_list.uniq! { |game| game['pcgw_id'].downcase }

game_array = []

games_list.each do |game|
  game_array << "#{game['pcgw_id']}\t#{game['title']}\tn/a"
end

File.open("pcgw_catalog.txt", "w+") do |f|
  game_array.each { |element| f.puts(element) }
end
