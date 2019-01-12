# Generate a list of PCGamingWiki articles with release dates and developers.
# This doesn't work because it hits a limit of 5000 pages in a given query.
require 'open-uri'
require 'json'

games_list = []
index = 0

loop do
  if index == 0
    offset = 0
    api_url = "https://pcgamingwiki.com/w/api.php?action=askargs&conditions=Category:Games&printouts=Developed%20by|Release%20date&parameters=limit%3D500&format=json"
  else
    offset = index * 500
    api_url = "https://pcgamingwiki.com/w/api.php?action=askargs&conditions=Category:Games&printouts=Developed%20by|Release%20date&parameters=limit%3D500%7Coffset%3D#{offset}&format=json"
  end

  games_json = JSON.load(open(api_url))

  games_json["query"]["results"].each do |page|
    game = {}
    page = page[1]
    game["title"] = page["fulltext"]
    game["fullurl"] = page["fullurl"]
    game["pcgw_id"] = page["fullurl"].sub('//pcgamingwiki.com/wiki/', '')
    if page["printouts"]["Release date"] != []
      game["release_date"] = page["printouts"]["Release date"][0]["timestamp"]
    else 
      game["release_date"] = ""
    end

    if page["printouts"]["Developed by"] != []
      game["developer"] = page["printouts"]["Developed by"][0]["fulltext"].sub('Company:', '')
    else 
      game["developer"] = ""
    end

    games_list << game
  end

  break if games_json["query-continue-offset"].nil?
  puts index
  break if index > 60
  index += 1
end

File.write('pcgw_games_list.json', games_list.to_json)
