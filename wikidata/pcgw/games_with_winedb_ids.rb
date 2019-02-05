require 'open-uri'
require 'json'

games = []

index = 0

loop do
  if index == 0
    offset = 0
    api_url = "https://pcgamingwiki.com/w/api.php?action=askargs&conditions=Category:Games|WineHQ%20AppID::%2B&printouts=WineHQ%20AppID|Steam%20AppID&parameters=limit=500&format=json"
  else
    offset = index * 500
    api_url = "https://pcgamingwiki.com/w/api.php?action=askargs&conditions=Category:Games|WineHQ%20AppID::%2B&printouts=WineHQ%20AppID|Steam%20AppID&parameters=limit=500|offset=#{offset}&format=json"
  end

  games_json = JSON.load(open(api_url))

  games_json['query']['results'].each do |name, game|
    # puts game.inspect

    game_object = {}

    game_object[:pcgw_id] = game['fullurl'].gsub('//pcgamingwiki.com/wiki/', '')
    # Replace some weird stuff the PCGW API does to certain characters in article URLs.
    game_object[:pcgw_id].gsub!('%26', '&')
    game_object[:pcgw_id].gsub!('%27', '\'')
    game_object[:pcgw_id].gsub!('%E2%80%93', '–')
    
    game_object[:winehq_id] = game['printouts']['WineHQ AppID'].first
    if game['printouts']['Steam AppID'] == []
      game_object[:steam_id] = nil
    else
      game_object[:steam_id] = game['printouts']['Steam AppID'].first
    end

    games << game_object
  end

  break if games_json["query-continue-offset"].nil?
  puts index
  index += 1
end

File.write('games_with_winedb_ids.json', games.to_json)
