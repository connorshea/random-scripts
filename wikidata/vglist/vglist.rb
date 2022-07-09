# frozen_string_literal: true

##
# USAGE:
#
# This script pulls down every game from vglist and then - based on their Wikidata IDs - will update their Wikidata items with the vglist ID, if it exists.
#
# ENVIRONMENT VARIABLES:
#
# USE_VGLIST_API (optional): defaults to false, whether to actually pull all the games down from the vglist API or to use the stored vglist_games.json file. Used for repeated runs so the vglist API doesn't get hit so many times.
# VGLIST_EMAIL (optional): email address for your vglist account
# VGLIST_TOKEN (optional): access token for your vglist account
# WIKIDATA_USERNAME: username for Wikidata account
# WIKIDATA_PASSWORD: password for Wikidata account

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'nokogiri'
  gem 'ruby-progressbar', '~> 1.10'
  gem 'graphql-client', '~> 0.16.0'
end

require 'json'
require 'sparql/client'
require_relative '../wikidata_helper.rb'
require 'open-uri'
require "graphql/client"
require "graphql/client/http"

include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }
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

def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel WHERE
    {
      ?item wdt:P31 wd:Q7889; # instance of video game
      FILTER NOT EXISTS { ?item wdt:P8351 ?vglist_id . } # and no vglist ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  return sparql
end

if ENV['USE_VGLIST_API']
  module VGListGraphQL
    HTTP = GraphQL::Client::HTTP.new("https://vglist.co/graphql") do
      def headers(context)
        {
          "User-Agent": "vglist Wikidata Importer",
          "X-User-Email": ENV['VGLIST_EMAIL'],
          "X-User-Token": ENV['VGLIST_TOKEN'],
          "Content-Type": "application/json",
          "Accept": "*/*"
        }
      end
    end

    # Fetch latest schema on init, this will make a network request
    Schema = GraphQL::Client.load_schema(HTTP)

    Client = GraphQL::Client.new(schema: Schema, execute: HTTP)
  end

  GamesQuery = VGListGraphQL::Client.parse <<-'GRAPHQL'
    query($page: String) {
      games(after: $page) {
        nodes {
          id
          name
          wikidataId
        }
        pageInfo {
          hasNextPage
          pageSize
          endCursor
        }
      }
    }
  GRAPHQL
end

def get_wikidata_items_with_no_vglist_id_from_sparql
  sparql_endpoint = "https://query.wikidata.org/sparql"

  client = SPARQL::Client.new(
    sparql_endpoint,
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 3.0" }
  )

  rows = client.query(query)

  return rows
end

if ENV['USE_VGLIST_API']
  puts "Using the vglist API to get all the games on the site."

  vglist_games = []
  next_page_cursor = nil

  # If it's nil or has a value (aka it's not false), then continue looping.
  while next_page_cursor.nil? || next_page_cursor
    # Sleep for half a second between each iteration.
    sleep 0.5
    puts "#{vglist_games.length} games catalogued so far."
    response = VGListGraphQL::Client.query(GamesQuery, variables: { page: next_page_cursor })

    response.data.games.nodes.each do |game|
      # Dup it otherwise you'll get a frozen hash error.
      game_hash = game.to_h.dup
      # Rename the wikidata id attribute to use snake case.
      game_hash['wikidata_id'] = game_hash['wikidataId']
      game_hash.delete('wikidataId')
      vglist_games << game_hash.to_h unless game.wikidata_id.nil?
    end

    if response.data.games.page_info.has_next_page
      next_page_cursor = response.data.games.page_info.end_cursor 
    else
      next_page_cursor = false
    end
  end

  File.write('vglist_games.json', JSON.pretty_generate(vglist_games))
else
  puts "Reading data from vglist_games.json, if you want to use the vglist API to get the data set the USE_VGLIST_API environment variable."

  vglist_games = JSON.parse(File.read('vglist_games.json'))
end

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

puts "#{vglist_games.count} games on vglist"

wikidata_rows = get_wikidata_items_with_no_vglist_id_from_sparql

wikidata_items = []

wikidata_rows.each do |row|
  key_hash = row.to_h
  wikidata_item = {
    name: key_hash[:itemLabel].to_s,
    wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/Q', '')
  }

  wikidata_items << wikidata_item
end

# Get all the Wikidata IDs that are in the vglist_games set and on wikidata with no vglist ID.
wikidata_ids_intersection = (vglist_games.map { |g| g['wikidata_id'].to_s } & wikidata_items.map { |item| item[:wikidata_id] })

puts "#{wikidata_ids_intersection.count} games can be matched based on Wikidata IDs."

progress_bar = ProgressBar.create(
  total: vglist_games.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

games_that_can_be_matched = 0
games_that_have_different_names = 0

vglist_games.each do |game|
  # Check if the Wikidata ID is represented, and skip if it isn't.
  if !wikidata_ids_intersection.include?(game['wikidata_id'].to_s)
    progress_bar.increment
    next
  end

  # Get the Wikidata item for the current vglist game.
  wikidata_item_for_current_game = wikidata_items.find { |item| item[:wikidata_id] == game['wikidata_id'].to_s }

  # Make sure the game doesn't already have a vglist ID.
  existing_claims = WikidataHelper.get_claims(entity: wikidata_item_for_current_game[:wikidata_id], property: 'P8351')
  if existing_claims != {} && !existing_claims.nil?
    progress_bar.log "SKIP: This item already has a vglist ID."
    progress_bar.increment
    next
  end

  # Make sure they have the same or a very similar name.
  if games_have_same_name?(game['name'], wikidata_item_for_current_game[:name])
    games_that_can_be_matched += 1
    begin
      claim = wikidata_client.create_claim("Q#{wikidata_item_for_current_game[:wikidata_id]}", "value", "P8351", "\"#{game['id']}\"")
      progress_bar.log "SUCCESS: Updated Q#{wikidata_item_for_current_game[:wikidata_id]} with vglist ID of #{game['id']}."
    rescue MediawikiApi::ApiError => e
      progress_bar.log e
    end
    # sleep 1
  else
    progress_bar.log "NAME MISMATCH: #{game['name']} can be matched based on its Wikidata ID, but the name on Wikidata differs from the one on vglist."
    progress_bar.log "NAME MISMATCH: (vglist ID: #{game['id']}, Wikidata name: #{wikidata_item_for_current_game[:name]}, Wikidata ID: #{wikidata_item_for_current_game[:wikidata_id]})"
    games_that_have_different_names += 1
  end

  progress_bar.increment
end

progress_bar.finish unless progress_bar.finished?

puts "#{games_that_can_be_matched} games matched based on Wikidata ID."
puts "#{games_that_have_different_names} games can be matched based on Wikidata ID but have different names."
