# frozen_string_literal: true
# This script adds the game mode property to games with Steam IDs
# that don't have a game mode defined. Steam provides game mode info,
# so we can use that to get the data for Wikidata.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'nokogiri'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'sparql/client'
require 'json'
require 'open-uri'
require 'net/http'
require 'mediawiki_api'
require 'mediawiki_api/wikidata/wikidata_client'
require_relative '../wikidata_helper.rb'

include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

# Returns a list of Wikidata items with a Steam AppID and no game mode property.
def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?steamAppId {
      ?item wdt:P31 wd:Q7889; # instance of video game
        wdt:P1733 ?steamAppId. # items with a Steam App ID.
      FILTER NOT EXISTS { ?item wdt:P404 ?gameMode . } # with no game mode
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  sparql
end

wikidata_client = MediawikiApi::Wikidata::WikidataClient.new 'https://www.wikidata.org/w/api.php'
wikidata_client.log_in(ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"])

sparql_client = SPARQL::Client.new(
  "https://query.wikidata.org/sparql",
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 3.1" }
)

# Get the response from the Wikidata query.
sparql = query
rows = sparql_client.query(sparql)

# Game Mode Wikidata IDs. Steam only supports single and multiplayer.
game_mode_wikidata_ids = {
  singleplayer: 208850,
  multiplayer: 6895044
}

puts "Got #{rows.count} items."

progress_bar = ProgressBar.create(
  total: rows.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

# Iterate through every item returned by the SPARQL query.
rows.each_with_index do |row, index|
  progress_bar.increment

  row = row.to_h
  # Get the English label for the item.
  name = row[:itemLabel].to_s
  # Get the item ID.
  item = row[:item].to_s.gsub('http://www.wikidata.org/entity/', '')

  current_platforms = []

  existing_claims = WikidataHelper.get_claims(entity: item, property: 'P404')
  if existing_claims != {}
    progress_bar.log "This item already has a game mode."
    next
  end

  # Get the Steam AppID
  steam_appid = row[:steamAppId]
  steam_url = "https://store.steampowered.com/app/#{steam_appid}"

  uri = URI("https://store.steampowered.com/api/appdetails/?appids=#{steam_appid}")
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = 'Valve/Steam HTTP Client 1.0 (tenfoot)'
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) {|http|
    http.request(request)
  }

  # Parse the JSON response to get the game's 'categories', which includes stuff like Steam cloud, single-player, multiplayer, etc.
  response = JSON.parse(response.body)
  categories = response&.dig(response&.keys&.first, 'data', 'categories')

  # If categories is nil, that means there was no categories data in the response
  # from Steam, which suggests the Steam App ID was wrong, Steam has
  # started rate limiting us, or the Steam page doesn't have this info.
  if categories.nil?
    # If no categories are found, print a failure message and the Steam URL.
    progress_bar.log "Steam request failed for #{name}."
    progress_bar.log steam_url
    progress_bar.log ''
    next
  end

  categories = categories.map { |category| category['description'] }
  categories = categories.filter { |category| ['Single-player', 'Multi-player'].include?(category) }
  categories = categories.map do |category|
    category = :singleplayer if category == 'Single-player'
    category = :multiplayer if category == 'Multi-player'
    category
  end

  # Skip to the next one if there aren't any game modes found in the Steam categories.
  if categories.empty?
    progress_bar.log "No relevant categories found for #{name}."
    next
  end

  progress_bar.log "Adding #{categories.join(', ')} to #{name}."
  progress_bar.log "#{row[:item].to_s}"

  # Try to create the claim for each game mode, report an error if it fails for any reason.
  categories.each do |category|
    begin
      wikidata_game_mode_identifier = {
        "entity-type": "item",
        "numeric-id": game_mode_wikidata_ids[category],
        "id": "Q#{game_mode_wikidata_ids[category]}"
      }
      claim = wikidata_client.create_claim(item, "value", "P404", wikidata_game_mode_identifier.to_json)
    rescue => error
      progress_bar.log "ERROR: #{error}"
    end
  end

  # Sleep for 1 second between edits to make sure we don't hit the Wikidata
  # or Steam rate limits.
  progress_bar.log ''
  sleep(1)
end

progress_bar.finish unless progress_bar.finished?
