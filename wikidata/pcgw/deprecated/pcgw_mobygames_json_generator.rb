# frozen_string_literal: true
# Quick script to get all the games on Wikidata that have both MobyGames and
# PCGW IDs, and then turn that into a JSON file.
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
end

require 'json'
require 'sparql/client'
require 'open-uri'

def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?pcgwId ?mobyGamesId
    {
      ?item wdt:P31 wd:Q7889; # video games
            wdt:P6337 ?pcgwId; # items with a PCGW ID.
            wdt:P1933 ?mobyGamesId. # items with a MobyGames ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  return sparql
end

sparql_endpoint = "https://query.wikidata.org/sparql"

client = SPARQL::Client.new(
  sparql_endpoint,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 2.6" }
)

rows = client.query(query)

wikidata_items = []

rows.each do |row|
  row = row.to_h

  wikidata_id = row[:item].to_s.gsub('http://www.wikidata.org/entity/', '')

  # Prevent duplication when a game has multiple MobyGames IDs.
  if wikidata_items.any? { |item| item[:wikidata_id] == wikidata_id }
    index = wikidata_items.find_index { |item| item[:wikidata_id] == wikidata_id }
    wikidata_items[index][:mobygames_ids] << row[:mobyGamesId].to_s
  else
    wikidata_items << {
      name: row[:itemLabel].to_s,
      wikidata_id: wikidata_id,
      mobygames_ids: [row[:mobyGamesId].to_s],
      pcgw_id: row[:pcgwId].to_s
    }
  end
end

File.write('pcgw_mobygames.json', JSON.pretty_generate(wikidata_items))
