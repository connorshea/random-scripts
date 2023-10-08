# frozen_string_literal: true

##
# USAGE:
#
# This script gets all the games in Wikidata with vglist IDs that are dead.

require 'bundler/inline'


gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'nokogiri'
end

require 'json'
require 'sparql/client'
require 'open-uri'
require 'net/http'

# Query to find all items that are video games, video game mods, video
# game compilations, or video game expansion packs.
def query
  <<-SPARQL
    SELECT DISTINCT ?item ?vglistId WHERE {
      ?item wdt:P8351 ?vglistId.
    }
  SPARQL
end

sparql_endpoint = "https://query.wikidata.org/sparql"

client = SPARQL::Client.new(
  sparql_endpoint,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
)

rows = client.query(query)

vglist_ids_in_wikidata = rows.map { |row| row['vglistId'].to_s.to_i }

vglist_ids = JSON.parse(File.read('vglist_games.json')).map { |g| g['id'].to_i }

# Find all vglist IDs from Wikidata that don't exist in vglist.
vglist_ids_in_wikidata_not_in_vglist = vglist_ids_in_wikidata - vglist_ids

vglist_ids_in_wikidata_not_in_vglist.each do |id|
  row_for_id = rows.find { |row| row['vglistId'].to_s.to_i == id }
  puts "Wikidata URL: #{row_for_id['item'].to_s}"
  puts "vglist ID: #{row_for_id['vglistId'].to_s.to_i}"
end

puts vglist_ids_in_wikidata_not_in_vglist.inspect

puts 'Done.'
