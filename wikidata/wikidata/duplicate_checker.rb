# The goal of this script is to gather the labels of all video game items on
# Wikidata, and then check for duplicates amongst those.
#
# Once we have the list of duplicates and their QIDs, we compare the QIDs
# of the duplicate items against a list of QIDs from a text file, and then
# print out all of the sets of duplicates that have a QID from the text file.
#
# We ran a mass-import of games from Steam that added around 27,000 games to
# Wikidata, and we want to go back and make sure that we resolve any dupes
# that may have been created.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'nokogiri'
  gem 'sparql-client', '~> 3.1.0'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
  gem 'debug'
  gem 'wikidatum', '~> 0.3.3'
end

require 'debug'
require 'json'
require 'net/http'
require 'wikidatum'
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

  [query1, query2, query3]
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
  sparql_query1, sparql_query2, sparql_query3 = queries_with_labels
  items.concat(wikidata_rows(sparql_query1))
  items.concat(wikidata_rows(sparql_query2))
  items.concat(wikidata_rows(sparql_query3))
  File.open(File.join(File.dirname(__FILE__), 'items.json'), 'w')
  File.write(File.join(File.dirname(__FILE__), 'items.json'), items.to_json)
  items = JSON.parse(File.read(File.join(File.dirname(__FILE__), 'items.json')))
end


# Filter out items with no English label (they'll just return the QID as the label)
items.filter! do |item|
  !(item['name'] =~ /Q\d+/i)
end

dupes = []

items.map! do |item|
  {
    name: item['name'].downcase.gsub('&', 'and').freeze,
    wikidata_id: item['wikidata_id'].freeze
  }
end

progress_bar = ProgressBar.create(
  total: items.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

# Find duplicate names in the list of items.
items.dup.each do |item|
  progress_bar.increment
  items.each do |i|
    if i[:name] == item[:name] && i[:wikidata_id] != item[:wikidata_id]
      dupes << {
        item: item,
        dupe: i
      }
    end
  end
  # Drop the first item in the array
  items.shift
end

progress_bar.finish unless progress_bar.finished?

qids_to_check = File.read(File.join(File.dirname(__FILE__), 'qids.txt')).split("\n")

# Print out the results.
dupes.each do |dupe|
  [dupe[:dupe][:wikidata_id], dupe[:item][:wikidata_id]].each do |id|
    if qids_to_check.include?(id)
      puts "----------------"
      puts "Potential duplicate:"
      puts "- https://www.wikidata.org/wiki/#{dupe[:dupe][:wikidata_id]}: #{dupe[:dupe][:name]}"
      puts "- https://www.wikidata.org/wiki/#{dupe[:item][:wikidata_id]}: #{dupe[:item][:name]}"
    end
  end
end
