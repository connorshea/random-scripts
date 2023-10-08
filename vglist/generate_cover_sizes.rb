# frozen_string_literal: true

##
# USAGE:
#
# This script goes through every game on vglist and pulls the covers in each
# available size. This forces Rails to generate and store this data, which
# is useful after a mass-import of covers.
#
# ENVIRONMENT VARIABLES:
#
# VGLIST_EMAIL (optional): email address for your vglist account
# VGLIST_TOKEN (optional): access token for your vglist account

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'addressable'
  gem 'nokogiri'
  gem 'ruby-progressbar', '~> 1.10'
  gem 'graphql-client', '~> 0.16.0'
end

require 'json'
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
  query($page: String) {
    games(after: $page, first: 50) {
      nodes {
        id
        name
        smallCover: coverUrl(size: SMALL)
        mediumCover: coverUrl(size: MEDIUM)
        largeCover: coverUrl(size: LARGE)
      }
      pageInfo {
        hasNextPage
        pageSize
        endCursor
      }
    }
  }
GRAPHQL

puts "Using the vglist API to generate cover sizes for all the games on the site."

vglist_games_count = 0
next_page_cursor = nil

# If it's nil or has a value (aka it's not false), then continue looping.
while next_page_cursor.nil? || next_page_cursor
  # Sleep for 5 second between each iteration to avoid overloading the server by generating so many game covers.
  sleep 5
  puts "#{vglist_games_count} games checked so far."
  response = VGListGraphQL::Client.query(GamesQuery, variables: { page: next_page_cursor })

  vglist_games_count += response.data.games.nodes.count

  if response.data.games.page_info.has_next_page
    next_page_cursor = response.data.games.page_info.end_cursor 
  else
    next_page_cursor = false
  end
end
