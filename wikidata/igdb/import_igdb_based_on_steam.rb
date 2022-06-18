#####
# Use the IGDB dump to get Steam IDs for games and then use that information to
# match IGDB IDs to Wikidata items that already have a Steam ID.
#
# ENVIRONMENT VARIABLES:
#
# WIKIDATA_USERNAME: username for Wikidata account
# WIKIDATA_PASSWORD: password for Wikidata account
#####

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'nokogiri'
  gem 'sparql-client', '~> 3.1.0'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
  gem 'debug'
end

require 'debug'
require 'json'
require 'sparql/client'
# For comparing using Levenshtein Distance.
# https://stackoverflow.com/questions/16323571/measure-the-distance-between-two-strings-with-ruby
require "rubygems/text"
require_relative '../wikidata_helper.rb'

include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

def games_have_same_name?(name1, name2)
  name1 = name1.downcase
  name2 = name2.downcase
  return true if name1 == name2

  levenshtein = Class.new.extend(Gem::Text).method(:levenshtein_distance)

  distance = levenshtein.call(name1, name2)
  return true if distance <= 2

  replacements = [
    {
      before: '&',
      after: 'and'
    },
    {
      before: 'deluxe',
      after: ''
    },
    {
      before: ' (video game)',
      after: ''
    },
  ]
  replacements.each do |replacement|
    name1 = name1.gsub(replacement[:before], replacement[:after]).strip
    name2 = name2.gsub(replacement[:before], replacement[:after]).strip
  end

  return true if name1 == name2

  return false
end

# SPARQL query to get all the games on Wikidata that have a Steam ID and no IGDB ID.
def sparql_query
  return <<-SPARQL
    SELECT ?item ?itemLabel ?steamAppId WHERE {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P1733 ?steamAppId. # items with a Steam App ID.
      FILTER NOT EXISTS { ?item wdt:P5794 ?igdbId. } # with no IGDB ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,en". }
    }
  SPARQL
end

# Get the Wikidata rows from the Wikidata SPARQL query
def wikidata_rows
  sparql_client = SPARQL::Client.new(
    "https://query.wikidata.org/sparql",
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 3.1" }
  )

  # Get the response from the Wikidata query.
  rows = sparql_client.query(sparql_query)

  rows.map! do |row|
    key_hash = row.to_h
    {
      name: key_hash[:itemLabel].to_s,
      wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/Q', ''),
      steam_app_id: key_hash[:steamAppId].to_s.to_i
    }
  end

  rows
end

# Create and return an authenticated Wikidata Client.
def wikidata_client
  MediawikiApi::Wikidata::WikidataClient.new('https://www.wikidata.org/w/api.php').log_in(ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"])
end

# Pull the Steam ID out of a Steam URL.
#
# Supports the following formats:
# - 'https://store.steampowered.com/app/1418570/Zen_Trails'
# - 'https://store.steampowered.com/app/1281600'
#
# @param url [String]
# @returns [Integer, nil] Will return the Steam ID, or nil if no match was found in the URL (usually this means the URL was malformed).
def steam_id_from_url(url)
  url.slice!('https://store.steampowered.com/app/')
  m = url.match(/(\d+)\/?/)
  return nil if m.nil?
  m.captures.first.to_i
end

igdb_games = JSON.load(File.open(File.join(File.dirname(__FILE__), 'igdb_games.json'))).map do |game|
  game.transform_keys(&:to_sym)
end

puts "#{igdb_games.count} games!"

# Go over every IGDB Game in the JSON blob and add Steam IDs to the hashes
# so we can match them to Wikidata.
igdb_games.map! do |igdb_game|
  # Pull the Steam IDs from the game records, if there are any.
  external_games = igdb_game[:external_games].filter { |ext_game| ext_game['category'] == 1 }.map { |ext_game| ext_game['url'] }.compact
  websites = igdb_game[:websites].filter { |website| website['category'] == 13 }.map { |website| website['url'] }.compact
  # Set Steam IDs on the given IGDB hash.
  igdb_game[:steam_ids] = external_games.concat(websites).uniq.map { |url| steam_id_from_url(url) }
  igdb_game
end

# Filter down to only the IGDB games that have Steam IDs.
igdb_games.filter! { |igdb_game| igdb_game[:steam_ids].count > 0 }

rows = wikidata_rows

steam_ids_from_wikidata = rows.map { |row| row[:steam_app_id] }

# Filter down to IGDB Games where one of the Steam ID exists for an item in
# Wikidata, where that Wikidata item has no IGDB ID. Essentially, get the
# intersection of the SPARQL query and the IGDB games with Steam IDs.
igdb_games.filter! do |igdb_game|
  igdb_game[:steam_ids].any? { |id| steam_ids_from_wikidata.include?(id) }
end

puts "There are #{igdb_games.count} items in Wikidata with a matching Steam ID from IGDB and no corresponding IGDB ID."

# TODO: Add a progress bar.

# Iterate over all the IGDB Games and find the records that match a Wikidata
# item. Then add the IGDB ID to the given item in Wikidata.
igdb_games.each do |igdb_game|
  puts
  matching_wikidata_items = []
  igdb_game[:steam_ids].each do |steam_id|
    matching_wikidata_items << rows.find { |row| row[:steam_app_id] == steam_id }
  end

  # Filter out any nils
  matching_wikidata_items.compact!

  next if matching_wikidata_items.empty?

  # Filter out games that don't have the same name on IGDB and Wikidata.
  # This is to prevent issues with false-positive matches due to incorrect Steam IDs.
  matching_wikidata_items.filter! do |wikidata_item|
    games_have_same_name?(igdb_game[:name], wikidata_item[:name])
  end

  next if matching_wikidata_items.empty?

  # Just skip this if there's more than one match, no need to handle this case for now.
  next if matching_wikidata_items.count > 1

  puts "IGDB GAME: #{igdb_game[:name]}"

  matching_wikidata_item = matching_wikidata_items.first

  # TODO: Add the IGDB ID to the relevant Wikidata item.
end
