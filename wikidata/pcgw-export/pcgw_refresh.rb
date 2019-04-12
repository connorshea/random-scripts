# frozen_string_literal: true

# This can be used to purge the cache of a bunch of pages at once.

require 'sparql/client'
require 'json'
require 'net/http'
require 'rest-client'

endpoint = "https://query.wikidata.org/sparql"

def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?pcgw_id WHERE
    {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P6337 ?pcgw_id. # with a PCGW ID
      FILTER NOT EXISTS { ?item wdt:P400 ?platform . } # with no platforms
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  return sparql
end

client = SPARQL::Client.new(endpoint, :method => :get)

rows = client.query(query)

rows.each do |row|
  key_hash = row.to_h
  game = key_hash[:pcgw_id].to_s
  require 'rest-client'
  
  RestClient::Request.execute(
    method: :post,
    url: "https://pcgamingwiki.com/w/api.php?action=purge&titles=#{game}&format=json",
    raw_response: true)
end
