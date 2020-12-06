# Testing to find wikidata entries for games.
require 'cgi'
require 'open-uri'
require 'json'

page_name = "Half-Life 2"
pcgw_api_url = "https://pcgamingwiki.com/w/api.php?action=askargs&conditions=Wikipedia::#{CGI.escape(page_name)}&printouts=Steam%20AppID%7CWineHQ%20AppID&format=json"

puts JSON.load(open(pcgw_api_url))

wikidata_video_games = JSON.load(open('https://gist.githubusercontent.com/connorshea/8b9922c6408f71192c5e953e8edc1caa/raw/af652273994b520c2d4c0c9ccb6b6b8686a5c544/wikidata-video-games.json'))

wikidata_identifiers = []

wikidata_video_games.each do |game|
  wikidata_identifiers << game["item"].sub('http://www.wikidata.org/entity/', '')
end

File.write('wikidata_identifiers.txt', wikidata_identifiers.to_json)

