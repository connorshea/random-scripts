# frozen_string_literal: true
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'json'
require 'sparql/client'
require_relative '../wikidata_helper.rb'
require 'open-uri'

include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?steam_id WHERE
    {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P1733 ?steam_id. # with a Steam App ID
      FILTER NOT EXISTS { ?item wdt:P7597 ?lutris_id . } # and no Lutris ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  return sparql
end

def get_wikidata_items_with_steam_and_no_lutris_from_sparql
  sparql_endpoint = "https://query.wikidata.org/sparql"

  client = SPARQL::Client.new(
    sparql_endpoint,
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 2.6" }
  )

  rows = client.query(query)

  return rows
end

# For comparing using Levenshtein Distance.
# https://stackoverflow.com/questions/16323571/measure-the-distance-between-two-strings-with-ruby
require "rubygems/text"

def games_have_same_name?(name1, name2)
  name1 = name1.downcase
  name2 = name2.downcase
  return true if name1 == name2

  levenshtein = Class.new.extend(Gem::Text).method(:levenshtein_distance)

  distance = levenshtein.call(name1, name2)
  return true if distance <= 2

  name1 = name1.gsub('&', 'and')
  name2 = name2.gsub('&', 'and')
  name1 = name1.gsub('deluxe', '').strip
  name2 = name2.gsub('deluxe', '').strip

  return true if name1 == name2

  return false
end

if ENV['USE_LUTRIS_API']
  puts "Using the Lutris API to get all the games on the site."

  # Lutris API URL
  url = "https://lutris.net/api/games?format=json"
  response = JSON.load(open(URI.parse(url)))

  puts JSON.pretty_generate(response)

  url = response["next"]

  lutris_games = []
  lutris_games.concat(response["results"])

  while response["next"] != nil
    response = JSON.load(open(URI.parse(url)))

    lutris_games.concat(response["results"])
    url = response["next"]
    sleep 5
    puts "#{lutris_games.count} games so far..."
  end

  File.write('lutris_games.json', JSON.pretty_generate(lutris_games))
else
  puts "Reading data from lutris_games.json, if you want to use the Lutris API to get the data set the USE_LUTRIS_API environment variable."

  lutris_games = JSON.parse(File.read('lutris_games.json'))
end

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

puts "#{lutris_games.count} games on Lutris"

wikidata_rows = get_wikidata_items_with_steam_and_no_lutris_from_sparql

wikidata_items = []

wikidata_rows.each do |row|
  key_hash = row.to_h
  wikidata_item = {
    name: key_hash[:itemLabel].to_s,
    steam_id: key_hash[:steam_id].to_s.to_i,
    wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')
  }

  wikidata_items << wikidata_item
end

steam_ids_on_wikidata = wikidata_items.map { |item| item[:steam_id] }

games_with_steam_ids = lutris_games.filter { |game| !game['steamid'].nil? }
steam_ids_on_lutris = games_with_steam_ids.map { |game| game['steamid'] }

# Get all the Steam IDs that are on both Wikidata and Lutris.
steam_ids_intersection = (steam_ids_on_wikidata & steam_ids_on_lutris)

puts "#{steam_ids_intersection.count} games can be matched based on Steam App IDs."

progress_bar = ProgressBar.create(
  total: lutris_games.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

games_that_can_be_matched = 0
games_that_have_different_names = 0

lutris_games.each do |game|
  # Check if the Steam ID is represented on Steam, and skip if it isn't.
  if !steam_ids_intersection.include?(game['steamid'])
    progress_bar.increment
    next
  end

  # Get the Wikidata item for the current Lutris game.
  wikidata_item_for_current_game = wikidata_items.find { |item| item[:steam_id] == game['steamid'] }

  # Make sure the game doesn't already have a Lutris ID.
  existing_claims = WikidataHelper.get_claims(entity: wikidata_item_for_current_game[:wikidata_id], property: 'P7597')
  if existing_claims != {}
    progress_bar.log "This item already has a Lutris ID."
    progress_bar.increment
    next
  end

  # Make sure they have the same or a very similar name.
  if games_have_same_name?(game['name'], wikidata_item_for_current_game[:name])
    games_that_can_be_matched += 1
    begin
      claim = wikidata_client.create_claim(wikidata_item_for_current_game[:wikidata_id], "value", "P7597", "\"#{game['slug']}\"")
      progress_bar.log "Updated #{wikidata_item_for_current_game[:wikidata_id]} with Lutris ID of #{game['slug']}."
    rescue MediawikiApi::ApiError => e
      progress_bar.log e
    end
    sleep 1
  else
    progress_bar.log "#{game['name']} can be matched based on its Steam App ID, but the name on Wikidata differs from the one on Lutris. (Steam: #{game['steamid']}, Wikidata name: #{wikidata_item_for_current_game[:name]})"
    games_that_have_different_names += 1
  end

  progress_bar.increment
end

puts "#{games_that_can_be_matched} games matched based on Steam ID."
puts "#{games_that_have_different_names} games can be matched based on Steam ID but have different names."

progress_bar.finish unless progress_bar.finished?
