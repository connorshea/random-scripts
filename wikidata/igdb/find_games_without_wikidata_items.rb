###
# The goal of this script is to analyze all the games on IGDB with a Steam
# ID and which are not represented (either based on matching Steam ID or
# IGDB ID) on Wikidata.
#
# This will then be piped into a script for importing new games using their
# information from Steam.
##

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
require 'net/http'
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

# SPARQL query to get all the games on Wikidata that have a Steam ID.
def steam_ids_query
  return <<-SPARQL
    SELECT ?item ?itemLabel ?steamAppId WHERE {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P1733 ?steamAppId. # items with a Steam App ID.
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,en". }
    }
  SPARQL
end

def igdb_ids_query
  return <<-SPARQL
    SELECT ?item ?itemLabel ?igdbId WHERE {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P5794 ?igdbId. # items with an IGDB ID.
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,en". }
    }
  SPARQL
end

# Get the Wikidata rows from the Wikidata SPARQL query
def steam_rows
  sparql_client = SPARQL::Client.new(
    "https://query.wikidata.org/sparql",
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 3.1" }
  )

  # Get the response from the Wikidata query.
  steam_rows = sparql_client.query(steam_ids_query)

  steam_rows.map! do |row|
    key_hash = row.to_h
    {
      name: key_hash[:itemLabel].to_s,
      wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/Q', ''),
      steam_app_id: key_hash[:steamAppId].to_s.to_i
    }
  end

  steam_rows
end

def igdb_rows
  sparql_client = SPARQL::Client.new(
    "https://query.wikidata.org/sparql",
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 3.1" }
  )

  # Get the response from the Wikidata query.
  igdb_rows = sparql_client.query(igdb_ids_query)

  igdb_rows.map! do |row|
    key_hash = row.to_h
    {
      name: key_hash[:itemLabel].to_s,
      wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/Q', ''),
      igdb_id: key_hash[:igdbId].to_s
    }
  end

  igdb_rows
end

def get_details_from_steam(app_id)
  uri = URI("https://store.steampowered.com/api/appdetails/?appids=#{app_id}")
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = 'Valve/Steam HTTP Client 1.0 (tenfoot)'
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) {|http|
    http.request(request)
  }

  # Parse the JSON response to get game information.
  JSON.parse(response.body)
end

puts 'Querying Wikidata...'
igdb_ids_from_wikidata = igdb_rows.map { |row| row.dig(:igdb_id) }
steam_ids_from_wikidata = steam_rows.map { |row| row.dig(:steam_app_id) }

igdb_games = JSON.parse(File.read('./igdb_games.json'))

# Exclude games if:
# - There are no external games
# - It's not a main game
# - There's no release date set
# - The game status is early access
# - The game has no Steam IDs.
#
# These are fairly arbitrary, but it's mostly about ensuring relatively high
# quality for the games being imported.
puts 'Filtering out various games...'
igdb_games.reject! { |game| game['status'] == 4 }
igdb_games.reject! { |game| game['first_release_date'].nil? }
igdb_games.reject! { |game| game['external_games'].empty? }
igdb_games.reject! { |game| game['category'] != 0 }
igdb_games.reject! do |game|
  game['external_games'].select { |external_game| external_game['category'] == 1 }.map do |external_game|
    external_game['url']&.match(/https:\/\/store\.steampowered\.com\/app\/(\d+)/)&.captures&.first
  end.compact.empty?
end

steam_ids_to_import = []

progress_bar = ProgressBar.create(
  total: igdb_games.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

# Shuffle the games so we don't pointlessly re-check the same games at the start every time
igdb_games.shuffle.each do |igdb_game|
  progress_bar.log 'Checking IGDB game...'
  progress_bar.increment

  # Skip if the IGDB ID for this game is already on Wikidata.
  if igdb_ids_from_wikidata.include?(igdb_game['slug'])
    progress_bar.log 'Skipping because IGDB ID is already on Wikidata'
    next
  end

  # Get Steam IDs for games
  steam_ids_for_game = igdb_game['external_games'].select { |external_game| external_game['category'] == 1 }.map { |external_game| external_game['url']&.match(/https:\/\/store\.steampowered\.com\/app\/(\d+)/)&.captures&.first }.compact
  # Skip if there's more than one Steam ID for this game, or if there is no Steam ID for the game.
  if steam_ids_for_game.length != 1
    progress_bar.log 'Skipping because no Steam ID or too many Steam IDs'
    next
  end

  steam_app_id = steam_ids_for_game.first
  # Skip if the Steam ID for this game is already on Wikidata.
  if steam_ids_from_wikidata.include?(steam_app_id.to_i)
    progress_bar.log 'Skipping because Steam ID is already on Wikidata'
    next
  end

  steam_json = get_details_from_steam(steam_ids_for_game.first)

  # Sleep to avoid being rate limited by Steam.
  sleep 2

  if steam_json.nil?
    progress_bar.log 'Skipping because Steam API call failed'
    next
  end

  if steam_json.dig(steam_app_id.to_s, 'success') == false
    progress_bar.log 'Skipping because Steam API call failed'
    next
  end

  if steam_json.dig(steam_app_id.to_s, 'data', 'release_date', 'coming_soon') == true
    progress_bar.log 'Skipping because game is unreleased'
    next
  end

  if steam_json.dig(steam_app_id.to_s, 'data', 'genres')&.map { |genre| genre['description'] }&.include?('Early Access')
    progress_bar.log 'Skipping because game is early access'
    next
  end

  supported_languages = steam_json.dig(steam_app_id.to_s, 'data', 'supported_languages')&.split(',') || []
  unless supported_languages.include?('English')
    progress_bar.log 'Skipping because game has no English support'
    next
  end

  progress_bar.log "Adding Steam ID #{steam_app_id} to list of games to import..."
  steam_ids_to_import << steam_app_id

  # Print the full list every 25 entries.
  if steam_ids_to_import.count % 25 == 0
    progress_bar.log 'Current list of Steam IDs to import:'
    progress_bar.log steam_ids_to_import
  end
end

progress_bar.finish unless progress_bar.finished?

puts 'Done!'
puts
steam_ids_to_import.each do |steam_id|
  puts steam_id
end
