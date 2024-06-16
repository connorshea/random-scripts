# frozen_string_literal: true

# The goal of this script is to gather the labels of all video game items on
# Wikidata, and then check for duplicates before we run an import of games
# into Wikidata using Steam IDs from IGDB.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'nokogiri'
  gem 'sparql-client', '~> 3.1.0'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
  gem 'debug'
end

require 'debug'
require 'json'
require 'net/http'
require 'sparql/client'
require_relative '../wikidata_helper.rb'

include WikidataHelper

# Have to limit it to 30k, otherwise the query times out. We run them all, to get up to 90k games.
# This is the only good way to consistently get the necessary response.
def queries_with_labels
  query1 = <<~SPARQL
    SELECT ?item ?itemLabel WHERE {
      {
        SELECT ?item WHERE {
          ?item wdt:P31 wd:Q7889.
        }
        ORDER BY ?item
        LIMIT 30000
      }
      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE],en". }
    }
  SPARQL

  query2 = <<~SPARQL
    SELECT ?item ?itemLabel WHERE {
      {
        SELECT ?item WHERE {
          ?item wdt:P31 wd:Q7889.
        }
        ORDER BY ?item
        LIMIT 30000
        OFFSET 30000
      }
      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE],en". }
    }
  SPARQL

  query3 = <<~SPARQL
    SELECT ?item ?itemLabel WHERE {
      {
        SELECT ?item WHERE {
          ?item wdt:P31 wd:Q7889.
        }
        ORDER BY ?item
        LIMIT 30000
        OFFSET 60000
      }
      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE],en". }
    }
  SPARQL

  query4 = <<~SPARQL
    SELECT ?item ?itemLabel WHERE {
      {
        SELECT ?item WHERE {
          ?item wdt:P31 wd:Q7889.
        }
        ORDER BY ?item
        LIMIT 30000
        OFFSET 90000
      }
      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE],en". }
    }
  SPARQL

  [query1, query2, query3, query4]
end

# Get the Wikidata rows from the Wikidata SPARQL query
def wikidata_rows(sparql_query)
  sparql_client = SPARQL::Client.new(
    "https://query.wikidata.org/sparql",
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
  )

  # Get the response from the Wikidata query.
  rows = sparql_client.query(sparql_query)

  rows.map! do |row|
    key_hash = row.to_h
    {
      name: key_hash[:itemLabel].to_s,
      wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')
    }
  end

  rows
end

# If items.json already exists, read it from the file. Otherwise, get it from Wikidata.
items = []
if File.exist?(File.join(File.dirname(__FILE__), 'items.json'))
  items = JSON.parse(File.read(File.join(File.dirname(__FILE__), 'items.json')))
else
  sparql_query1, sparql_query2, sparql_query3, sparql_query4 = queries_with_labels
  items.concat(wikidata_rows(sparql_query1))
  items.concat(wikidata_rows(sparql_query2))
  items.concat(wikidata_rows(sparql_query3))
  items.concat(wikidata_rows(sparql_query4))
  File.open(File.join(File.dirname(__FILE__), 'items.json'), 'w')
  File.write(File.join(File.dirname(__FILE__), 'items.json'), items.to_json)
  items = JSON.parse(File.read(File.join(File.dirname(__FILE__), 'items.json')))
end

# Filter out items with no English label (they'll just return the QID as the label)
items.filter! do |item|
  !(item['name'] =~ /Q\d+/i)
end

# An array of every single video game item on Wikidata.
items.map! do |item|
  {
    name: item['name'].downcase.gsub('&', 'and'),
    wikidata_id: item['wikidata_id']
  }
end.sort_by! { |item| item[:name] }

puts items.length

# Take the Steam IDs that were dumped from IGDB that we want to attempt to import into Wikidata.
# Then grab the names of all the games from IGDB that have those Steam IDs.
# Then check those against the names of all the games on Wikidata to filter out potential duplicates.
steam_ids = File.read(File.join(File.dirname(__FILE__), 'steam_ids.txt')).split("\n").map(&:strip)
igdb_games = JSON.parse(File.read('./igdb_games.json'))

puts steam_ids.length

igdb_games.each do |game|
  game['steam_ids'] = game['external_games'].select { |external_game| external_game['category'] == 1 }.map do |external_game|
    external_game['uid']
  end.compact
end

# Filter out games with no Steam IDs or the wrong category.
igdb_games.reject! { |game| game['steam_ids'].empty? }
igdb_games.reject! { |game| game['category'] != 0 }

puts igdb_games.length

# Get an array of every Steam ID and the name associated to each.
steam_ids_from_igdb = []
igdb_games.each do |game|
  game['steam_ids'].each do |steam_id|
    steam_ids_from_igdb << { steam_id: steam_id, name: game['name'].downcase.gsub('&', 'and') }
  end
end

steam_ids_from_igdb.sort_by! { |game| game[:steam_id] }

# Get the games from IGDB for every game listed in the steam IDs text file.
steam_igdb_intersection = steam_ids.map do |steam_id|
  steam_ids_from_igdb.bsearch { |game| steam_id <=> game[:steam_id] }
end.compact.sort_by { |game| game[:name] }

# Then compare those names to the names of every game on Wikidata, and remove
# any that are potential duplicates of existing games on Wikidata.
importable_steam_ids = steam_igdb_intersection.select do |game|
  if items.bsearch { |item| game[:name] <=> item[:name] }.nil?
    true
  else
    puts "Found a duplicate! #{game[:name]} / #{game[:steam_id]}"
    false
  end
end

5.times { puts }

importable_steam_ids.each do |game|
  puts game[:steam_id]
end
