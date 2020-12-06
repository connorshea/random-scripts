# Putting together the leftovers.json files.
require 'sparql/client'
require 'json'
require 'csv'

does_not_equal = JSON.load(File.read('does-not-equal.json'))

# SPARQL Query to find the, pass the Steam App ID and it'll return a query
# that finds any Wikidata items with that App ID.
def query(steam_app_id)
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel WHERE {
      ?item wdt:P1733 "#{steam_app_id}".
      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE],en". }
    }
    LIMIT 10
  SPARQL

  return sparql
end

# Finds Wikidata items based on the Steam App ID it's passed
def find_wikidata_item_by_steam_app_id(app_id)
  endpoint = "https://query.wikidata.org/sparql"
  client = SPARQL::Client.new(endpoint, :method => :get)
  sparql = query(app_id)
  begin
    rows = client.query(sparql)
  rescue SocketError => e
    puts e
    sleep 10
    return nil
  end

  # If there are 0 rows (no data returned) or more than one row, just skip it.
  return nil if rows.size != 1
  return_row = {}
  rows.each do |row|
    return_row = { url: row.to_h[:item].to_s, title: row.to_h[:itemLabel].to_s }
  end

  return return_row
end

pcgw_steam_ids = []

CSV.foreach(
  File.join(File.dirname(__FILE__), 'pcgw_steam_ids.csv'),
  skip_blanks: true,
  headers: false,
  encoding: 'ISO-8859-1'
) do |row|
  next if row[0].length > 40
  pcgw_steam_ids << {
    title: row[0],
    steam_app_id: row[1]
  }
end

leftovers = []

does_not_equal.each_with_index do |game, index|
  next if index < 400
  next if index > 600
  # next if game["checked_for_match"]
  game["pcgw_id"] = game["pcgw"].gsub(' ', '_')
  game["checked_for_match"] = false
  steam_app_id = pcgw_steam_ids.select { |pcgw_item| pcgw_item[:title] == game["pcgw"] }
  puts "STEAM APP ID: #{steam_app_id}"
  next if steam_app_id[0].nil?
  wikidata_item = find_wikidata_item_by_steam_app_id(steam_app_id[0][:steam_app_id])
  next if wikidata_item.nil?
  game["wikidata_item"] = wikidata_item[:url].sub('http://www.wikidata.org/entity/', '')
  leftovers << game
end

# puts does_not_equal

File.write('leftovers3.json', leftovers.to_json)

# system("open 'https://pcgamingwiki.com/wiki/#{does_not_equal[0]['pcgw_id']}'")
# wikidata_search_url = "https://www.wikidata.org/w/index.php?search=&search=#{does_not_equal[0]['wikidata'].gsub(' ', '+')}&title=Special%3ASearch&go=Go"
# system("open '#{wikidata_search_url}'")
