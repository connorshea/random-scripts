require 'sparql/client'
require "json"
require 'open-uri'

endpoint = "https://query.wikidata.org/sparql"
games = JSON.load(File.open('games_with_winedb_ids.json'))

def query(steamAppID)
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?wineHQ WHERE {
      ?item wdt:P1733 '#{steamAppID}' .
      OPTIONAL { ?item wdt:P600 ?wineHQ . }
      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE],en". }
    }
    LIMIT 5
  SPARQL

  return sparql
end

client = SPARQL::Client.new(endpoint, :method => :get)

games.each do |game|
  next if game['steam_id'].nil?
  sparql = query(game['steam_id'])
  return_value = client.query(sparql)

  puts 'Found no wikidata items' if return_value == []
  next if return_value == []

  item = return_value.first.to_h[:item].to_s
  item.gsub!('http://www.wikidata.org/entity/', '')

  # puts "https://www.wikidata.org/w/api.php?format=json&action=wbgetclaims&entity=#{item}&property=P600"
  response = JSON.load(open("https://www.wikidata.org/w/api.php?format=json&action=wbgetclaims&entity=#{item}&property=P600"))

  if response["claims"] == {}
    game['wikidata_item_has_winedb_id'] = false
  elsif !response['error'].nil?
    puts "ERROR: #{response['error']}"
  else
    game['wikidata_item_has_winedb_id'] = true
  end

  # puts response.inspect
end

puts games

games_with_no_winedb = games.filter { |game| game['wikidata_item_has_winedb_id'] == false }

puts "Missing WineHQ IDs vs total: #{games_with_no_winedb.length} / #{games.length}"

File.write('games_with_winedb_ids.json', games.to_json)
