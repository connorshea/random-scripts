# frozen_string_literal: true

##
# USAGE:
#
# This script pulls down every anime from AniList and then generates a
# mix'n'match catalogue TSV.
#
# ENVIRONMENT VARIABLES:
#
# USE_ANILIST_API (optional): defaults to false, whether to actually pull all the anime down from the AniList API or to use the stored anilist_anime.json file. Used for repeated runs so the AniList API doesn't get hit so many times.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'graphql-client', '~> 0.16.0'
end

require 'json'
require 'open-uri'
require "graphql/client"
require "graphql/client/http"

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

ANILIST_ANIME_PID = 'P8729'

module AniListGraphQL
  HTTP = GraphQL::Client::HTTP.new("https://graphql.anilist.co") do
    def headers(context)
      {
        "User-Agent": "AniList Wikidata Importer",
        "Content-Type": "application/json",
        "Accept": "*/*"
      }
    end
  end

  # Fetch latest schema on init, this will make a network request
  Schema = GraphQL::Client.load_schema(HTTP)

  Client = GraphQL::Client.new(schema: Schema, execute: HTTP)
end

AnimeQuery = AniListGraphQL::Client.parse <<-'GRAPHQL'
query ($page: Int, $perPage: Int, $search: String) {
  Page(page: $page, perPage: $perPage) {
    pageInfo {
      total
      currentPage
      lastPage
      hasNextPage
      perPage
    }
    media(search: $search, type: ANIME) {
      id
      title {
        english
        romaji
        native
      }
      format
      seasonYear
      season
      status
      studios {
        nodes {
          name
        }
      }
    }
  }
}
GRAPHQL

if ENV['USE_ANILIST_API']
  puts "Using the AniList API to get all the anime on the site."

  anilist_anime = []
  next_page = 1

  # If it's nil or has a value (aka it's not false), then continue looping.
  while next_page.nil? || next_page
    # Sleep for 2 seconds between each iteration.
    sleep 2
    puts "#{anilist_anime.length} anime catalogued so far."
    response = AniListGraphQL::Client.query(AnimeQuery, variables: { page: next_page, per_page: 50, search: nil })

    if response.data.nil?
      puts response.inspect
      break
    end
    response.data.page.media.each do |anime|
      # Dup it otherwise you'll get a frozen hash error.
      anime_hash = anime.to_h.dup
      # Rename the seasonYear attribute to use snake case.
      anime_hash['season_year'] = anime_hash['seasonYear']
      anime_hash.delete('seasonYear')
      # Map the studios list to just an array of names.
      anime_hash['studios'] = anime_hash['studios']['nodes'].map { |studio| studio['name'] }
      anilist_anime << anime_hash.to_h
    end

    if response.data.page.page_info.has_next_page
      next_page = response.data.page.page_info.current_page + 1
    else
      next_page = false
    end
  end

  File.write('anilist_anime_for_mixnmatch.json', JSON.pretty_generate(anilist_anime))
else
  puts "Reading data from anilist_anime_for_mixnmatch.json, if you want to use the AniList API to get the data set the USE_ANILIST_API environment variable."

  anilist_anime = JSON.parse(File.read('anilist_anime_for_mixnmatch.json'))
end

puts "#{anilist_anime.count} anime on AniList"

# Return the English title, the Romaji title, or the Native title, depending
# on which titles exist.
#
# @param title [Hash] hash with 'english', 'romaji', and 'native' keys.
# @return [String] This could theoretically be nil if the AniList API returns nil English AND Romaji AND native titles, but realistically that should never happen.
def anilist_title_converter(title)
  if !title['english'].nil?
    title['english']
  elsif !title['romaji'].nil?
    title['romaji']
  elsif !title['native'].nil?
    title['native']
  end
end

# Media formats and humanized names for them.
MEDIA_FORMAT_HASH = {
  'TV': 'TV show',
  'TV_SHORT': 'TV short',
  'MOVIE': 'movie',
  'SPECIAL': 'special episode',
  'OVA': 'OVA',
  'ONA': 'ONA',
  'MUSIC': 'music video'
}.freeze

# Map of MEDIA_FORMATs from AniList to Wikidata item types.
WIKIDATA_ITEM_TYPE_MAP = {
  'TV': 'Q63952888', # anime television series
  'TV_SHORT': 'Q63952888', # anime television series
  'MOVIE': 'Q20650540', # anime film
  'SPECIAL': nil, # can be multiple different things
  'OVA': 'Q220898', # original video animation
  'ONA': 'Q1047299', # original net animation
  'MUSIC': nil # hard to pin down what this should be.
}

anilist_anime_entries = []

anilist_anime.each do |anime|
  title = anilist_title_converter(anime['title'])

  humanized_format = MEDIA_FORMAT_HASH[anime['format'].to_sym] unless anime['format'].nil?

  # Generate a description based on the data we have.
  description = ''

  # Unreleased or Cancelled, if relevant. Otherwise, ignore the status.
  description += "Unreleased " if anime['status'] == 'NOT_YET_RELEASED'
  description += "Cancelled " if anime['status'] == 'CANCELLED'
  # The release year, if we have one.
  description += "#{anime['season_year']} " unless anime['season_year'].nil?
  # The type of anime, e.g. television short.
  description += "#{humanized_format}" unless humanized_format.nil?
  # The first one or two studios involved, if any.
  description += " by #{anime['studios'].first(2).join(' and ')}" unless anime['studios'].count.zero?
  # Add a period.
  description += '.'

  # Add a Q-ID for the type of item this is related to, or a blank string if nil.
  type = WIKIDATA_ITEM_TYPE_MAP[anime['format'].to_sym] unless anime['format'].nil?
  type ||= ''

  anilist_anime_entries << {
    id: anime['id'],
    title: title,
    description: description,
    type: type
  }
end

# Create lines for the TSV file.
lines = anilist_anime_entries.map do |entry|
  entry.values_at(:id, :title, :description, :type).join("\t")
end

File.write(File.join(File.dirname(__FILE__), 'anilist_anime_mixnmatch.tsv'), lines.join("\n"))
