# frozen_string_literal: true

##
# USAGE:
#
# This script finds games where all three are true:
# - Game has a Wikidata ID that redirects.
# - The Wikidata item that it redirects to already has a vglist ID, only one vglist ID, and that vglist ID is not the vglist ID of this game.
# - No one owns or has favorited the game on vglist.
#
# And then lists the game from vglist if all three of those criterion are true
# so the vglist games can be deleted manually.
#
# This script needs to have the redirects.json from the bad data finder before
# it can be run.
#
# ENVIRONMENT VARIABLES:
#
# VGLIST_EMAIL: email address for your vglist account
# VGLIST_TOKEN: access token for your vglist account

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'wikidatum', github: 'connorshea/wikidatum'
  gem 'addressable'
  gem 'nokogiri'
  gem 'graphql-client', '~> 0.16.0'
end

require 'json'
require 'wikidatum'
require 'open-uri'
require "graphql/client"
require "graphql/client/http"

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
  query($id: ID!) {
    game(id: $id) {
      id
      wikidataId
      name
      favoriters {
        totalCount
      }
      owners {
        totalCount
      }
    }
  }
GRAPHQL

wikidatum_client = Wikidatum::Client.new(
  user_agent: 'vglist redirect fixer',
  wikibase_url: 'https://www.wikidata.org'
)

redirects = JSON.parse(File.read('redirects.json'))

puts 'vglist IDs for games that can be deleted:'
redirects.each do |redirect|
  next if redirect['status'] != 'redirected'

  wikidata_id = redirect['wikidata_url'].gsub('https://www.wikidata.org/wiki/', '')

  item = wikidatum_client.item(id: wikidata_id, follow_redirects: true)
  vglist_id_statements = item.statements(properties: ['P8351'])

  vglist_ids_from_wikidata = vglist_id_statements.map { |statement| statement.to_h.dig(:data_value, :content, :string)&.to_i }
  vglist_id = redirect['vglist_url'].gsub('https://vglist.co/games/', '').to_i

  graphql_response = VGListGraphQL::Client.query(GamesQuery, variables: { id: vglist_id })

  # Game is invalid, return early.
  next if graphql_response.data.game.nil?

  # Return early if anyone owns or has favorited the game.
  next if graphql_response.data.game.favoriters.total_count > 0
  next if graphql_response.data.game.owners.total_count > 0

  # Return early if the Wikidata ID has this vglist ID already.
  next if vglist_ids_from_wikidata.include?(vglist_id)
  # Return early if the Wikidata item has more than one vglist ID.
  next if vglist_ids_from_wikidata.length > 1

  puts vglist_id
end

puts 'Done.'
