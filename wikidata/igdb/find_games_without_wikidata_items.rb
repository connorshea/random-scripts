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
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
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
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
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

def add_to_steam_exclusions_list(app_id)
  File.open('./steam_exclusions_list.txt', 'a') do |file|
    file.puts("#{app_id}")
  end
end

# Create 'steam_exclusions_list.txt' if it doesn't exist
File.open('./steam_exclusions_list.txt', 'w') unless File.exist?('./steam_exclusions_list.txt')

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
igdb_games.reject! { |game| game['first_release_date'].nil? }
igdb_games.reject! { |game| game['external_games'].empty? }
igdb_games.reject! { |game| game['category'] != 0 }
# Store the Steam IDs on the item so we don't have to keep re-calculating it.
igdb_games.each do |game|
  game['steam_ids'] = game['external_games'].select { |external_game| external_game['category'] == 1 }.map do |external_game|
    external_game['url']&.match(/https:\/\/store\.steampowered\.com\/app\/(\d+)/)&.captures&.first
  end.compact
end
puts 'Filtering out games with no Steam ID or more than one Steam ID...'
igdb_games.reject! do |game|
  game['steam_ids'].count != 1
end

steam_ids_to_import = []

steam_exclusions_list = File.readlines('./steam_exclusions_list.txt').map(&:chomp).map(&:strip).uniq

# Remove any games that are already on Wikidata.
puts 'Filtering out games that have IGDB IDs already on Wikidata...'
igdb_games.reject! { |game| igdb_ids_from_wikidata.include?(game['slug']) }
puts 'Filtering out games that have Steam IDs already on Wikidata...'
igdb_games.reject! { |game| steam_ids_from_wikidata.include?(game['steam_ids'].first.to_i) }

puts 'Filtering out games that are on the Steam exclusion list...'
igdb_games.reject! { |game| steam_exclusions_list.include?(game['steam_ids'].first) }

progress_bar = ProgressBar.create(
  total: igdb_games.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

GAME_TITLE_REGEX = /^[A-Za-zĀ-ſ0-9\s,.?!\-+*\/=_–—:;~\'’"„“«»\(\)\[\]&]+$/.freeze

# Shuffle the games so we don't pointlessly re-check the same games at the start every time
igdb_games.shuffle.each do |igdb_game|
  progress_bar.log 'Checking IGDB game...'
  progress_bar.increment

  steam_app_id = igdb_game['steam_ids'].first
  steam_json = get_details_from_steam(steam_app_id)

  # Sleep to avoid being rate limited by Steam.
  sleep 2

  if steam_json.nil?
    progress_bar.log 'Skipping because Steam API call failed'
    next
  end

  if steam_json.dig(steam_app_id.to_s, 'success') == false
    add_to_steam_exclusions_list(steam_app_id)
    progress_bar.log 'Skipping because Steam API call failed'
    next
  end

  if steam_json.dig(steam_app_id.to_s, 'data', 'release_date', 'coming_soon') == true
    add_to_steam_exclusions_list(steam_app_id)
    progress_bar.log 'Skipping because game is unreleased'
    next
  end

  if steam_json.dig(steam_app_id.to_s, 'data', 'type') == 'dlc'
    add_to_steam_exclusions_list(steam_app_id)
    progress_bar.log 'Skipping because this is a DLC'
    next
  end

  supported_languages = steam_json.dig(steam_app_id.to_s, 'data', 'supported_languages')
  unless supported_languages&.include?('English')
    add_to_steam_exclusions_list(steam_app_id)
    progress_bar.log "Skipping #{steam_app_id} because game has no English support"
    next
  end

  unless steam_json.dig(steam_app_id.to_s, 'data', 'name')&.match?(GAME_TITLE_REGEX)
    add_to_steam_exclusions_list(steam_app_id)
    progress_bar.log "Skipping #{steam_app_id} because game has non-English characters in title"
    next
  end

  progress_bar.log "Adding Steam ID #{steam_app_id} to list of games to import..."
  steam_ids_to_import << steam_app_id

  # Print the full list every 25 entries.
  if steam_ids_to_import.count % 25 == 0
    progress_bar.log 'Current list of Steam IDs to import:'
    progress_bar.log steam_ids_to_import
    steam_ids_to_import.last(25).each do |id|
      add_to_steam_exclusions_list(id)
    end
  end
end

progress_bar.finish unless progress_bar.finished?

puts 'Done!'
puts
steam_ids_to_import.each do |steam_id|
  puts steam_id
end
