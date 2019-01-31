require 'sparql/client'
require 'json'
require 'open-uri'

endpoint = "https://query.wikidata.org/sparql"
@client = SPARQL::Client.new(endpoint, :method => :get)
rows = []

def query(item, property)
  sparql = <<-SPARQL
    SELECT ?value ?valueLabel WHERE {
      wd:#{item} wdt:#{property} ?value .
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,en". }
    }
    LIMIT 10
  SPARQL

  return sparql
end

def get_wikilink(item)
  sparql = <<-SPARQL
    SELECT ?wikilink WHERE {
      ?wikilink schema:about wd:#{item} .
      ?wikilink schema:inLanguage "en" .
      ?wikilink schema:isPartOf <https://en.wikipedia.org/> .
    }
    LIMIT 1
  SPARQL

  rows = @client.query(sparql)

  return rows.first.to_h[:wikilink].to_s
end

def get_item_data(item)
  properties = {
    publishers: 'P123',
    platforms: 'P400',
    developers: 'P178',
    genres: 'P136',
    publication_dates: 'P577'
  }

  game = {}

  properties.each do |key, value|
    game[key] = get_property(item, value)
  end

  game[:wikipedia_url] = get_wikilink(item)

  # puts JSON.pretty_generate(game)
  return game
end

def get_property(item, property)
  sparql = query(item, property)
  rows = @client.query(sparql)
  hash = {}

  rows.map do |row|
    value = row.to_h[:value].to_s
    value_label = row.to_h[:valueLabel].to_s
    hash["#{value_label}"] = value
  end

  return hash
end

games = [
  'Q279744',
  'Q76255',
  'Q193581',
  'Q18951',
  'Q553308',
  'Q279446',
  'Q1361363',
  'Q513867'
]

# games = {
#   'Half-Life': 'Q279744',
#   'Call of Duty 4: Modern Warfare': 'Q76255',
#   'Half-Life 2': 'Q193581',
#   'Half-Life 2: Episode One': 'Q18951',
#   'Half-Life 2: Episode Two': 'Q553308',
#   'Portal 2': 'Q279446',
#   "Kirby's Epic Yarn": 'Q1361363',
#   'Doom': 'Q513867'
# }

games_with_data = []

games.each do |wikidata_id|
  game_hash = JSON.load(open("https://www.wikidata.org/w/api.php?action=wbgetentities&props=labels&ids=#{wikidata_id}&languages=en&format=json"))
  game_data = {}
  game_data[:name] = game_hash["entities"]["#{wikidata_id}"]["labels"]["en"]["value"]
  game_data[:wikidata_id] = wikidata_id
  game_data.merge!(get_item_data(wikidata_id))

  games_with_data << game_data
end

puts JSON.pretty_generate(games_with_data)
