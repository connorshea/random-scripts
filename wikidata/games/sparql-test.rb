# Test SPARQL queries for Wikidata.
#gem install sparql
#http://www.rubydoc.info/github/ruby-rdf/sparql/frames

require 'sparql/client'
require 'json'

endpoint = "https://query.wikidata.org/sparql"

def query(offset)
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel WHERE {
      ?item wdt:P31 ?sub0 .
      ?sub0 (wdt:P279)* wd:Q7889
    .
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,en"  }  
    }
    ORDER BY DESC(?itemLabel)
    LIMIT 100
    OFFSET #{offset}

  SPARQL

  return sparql
end

client = SPARQL::Client.new(endpoint, :method => :get)
rows = []

# Do either 5 iterations or the number specified in the first argument to the script.
iterations = (ARGV[0].nil? ? 5 : ARGV[0].to_i)

puts "Doing #{iterations} iterations..."

iterations.times do |i|
  puts "Iteration #{i}"
  offset = 100 * i
  sparql = query(offset)
  rows.concat(client.query(sparql))
end

puts "Number of rows: #{rows.size}"

games = []

rows.each do |row|
  game = {}

  row.to_h.keys.each do |key|
    next if row[key.to_sym].to_s == ""
    game[key] = row[key.to_sym].to_s
  end
  games << game
end

games_json = games.to_json

puts "Writing to games.json..."

File.write('games.json', games_json)
