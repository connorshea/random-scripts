# frozen_string_literal: true

##
# USAGE:
#
# This script pulls down every manga from AniList and then - based on their MAL IDs - will update their Wikidata items with the AniList ID, if it exists.
#
# ENVIRONMENT VARIABLES:
#
# USE_ANILIST_API (optional): defaults to false, whether to actually pull all the manga down from the AniList API or to use the stored anilist_manga.json file. Used for repeated runs so the AniList API doesn't get hit so many times.
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

ANILIST_MANGA_PID = 'P8731'
MAL_MANGA_PID = 'P4087'

def query
  return <<-SPARQL
    SELECT ?item ?itemLabel ?malId WHERE
    {
      VALUES ?mangaTypes {
        wd:Q21198342 # manga series
        wd:Q747381 # light novel
        wd:Q74262765 # manhwa series
        wd:Q1667921 # novel series
      }
      ?item wdt:P31 ?mangaTypes;
            wdt:#{MAL_MANGA_PID} ?malId. # with a MAL ID
      FILTER NOT EXISTS { ?item wdt:#{ANILIST_MANGA_PID} ?anilistId . } # and no AniList ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL
end

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

MangaQuery = AniListGraphQL::Client.parse <<-'GRAPHQL'
  query ($page: Int, $perPage: Int, $search: String) {
    Page(page: $page, perPage: $perPage) {
      pageInfo {
        total
        currentPage
        lastPage
        hasNextPage
        perPage
      }
      media(search: $search, type: MANGA) {
        id
        idMal
        title {
          english
          romaji
        }
      }
    }
  }
GRAPHQL

def get_wikidata_items_with_no_anilist_id_from_sparql
  sparql_endpoint = "https://query.wikidata.org/sparql"

  client = SPARQL::Client.new(
    sparql_endpoint,
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
  )

  rows = client.query(query)

  return rows
end

if ENV['USE_ANILIST_API']
  puts "Using the AniList API to get all the manga on the site."

  anilist_manga = []
  next_page = 1

  # If it's nil or has a value (aka it's not false), then continue looping.
  while next_page.nil? || next_page
    # Sleep for half a second between each iteration.
    sleep 0.5
    puts "#{anilist_manga.length} manga catalogued so far."
    response = AniListGraphQL::Client.query(MangaQuery, variables: { page: next_page, per_page: 50, search: nil })

    if response.data.nil?
      puts response.inspect
      break
    end

    response.data.page.media.each do |manga|
      # Dup it otherwise you'll get a frozen hash error.
      manga_hash = manga.to_h.dup
      # Rename the MAL ID attribute to use snake case.
      manga_hash['mal_id'] = manga_hash['idMal']
      manga_hash.delete('idMal')
      anilist_manga << manga_hash.to_h unless manga.id_mal.nil?
    end

    if response.data.page.page_info.has_next_page
      next_page = response.data.page.page_info.current_page + 1
    else
      next_page = false
    end
  end

  File.write('anilist_manga.json', JSON.pretty_generate(anilist_manga))
else
  puts "Reading data from anilist_manga.json, if you want to use the AniList API to get the data set the USE_ANILIST_API environment variable."

  anilist_manga = JSON.parse(File.read('anilist_manga.json'))
end

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

puts "#{anilist_manga.count} manga on AniList"

wikidata_rows = get_wikidata_items_with_no_anilist_id_from_sparql

wikidata_items = []

wikidata_rows.each do |row|
  key_hash = row.to_h
  wikidata_item = {
    name: key_hash[:itemLabel].to_s,
    wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/Q', ''),
    mal_id: key_hash[:malId].to_s
  }

  wikidata_items << wikidata_item
end

# Get all the Wikidata IDs that are in the anilist_manga set and on Wikidata with no AniList ID.
mal_ids_intersection = (anilist_manga.map { |manga| manga['mal_id'].to_s } & wikidata_items.map { |item| item[:mal_id] })

wikidata_ids_intersection = wikidata_items.select { |item| mal_ids_intersection.include?(item[:mal_id]) }.map { |item| item[:wikidata_id] }

puts "#{wikidata_ids_intersection.count} manga can be matched based on MAL IDs."

progress_bar = ProgressBar.create(
  total: anilist_manga.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

manga_that_can_be_matched = 0

anilist_manga.each do |manga|
  # Get the Wikidata item for the current AniList manga.
  wikidata_item_for_current_manga = wikidata_items.find { |item| item[:mal_id] == manga['mal_id'].to_s }

  # Skip if no relevant Wikidata ID can be found (either because the MAL ID
  # doesn't exist in Wikidata or the item already has an AniList ID).
  if wikidata_item_for_current_manga.nil?
    progress_bar.increment
    next
  end

  # Make sure the manga doesn't already have a AniList ID.
  existing_claims = WikidataHelper.get_claims(entity: wikidata_item_for_current_manga[:wikidata_id], property: ANILIST_MANGA_PID)
  if existing_claims != {} && !existing_claims.nil?
    progress_bar.log "This item already has a AniList manga ID."
    progress_bar.increment
    next
  end

  manga_that_can_be_matched += 1
  begin
    claim = wikidata_client.create_claim("Q#{wikidata_item_for_current_manga[:wikidata_id]}", "value", ANILIST_MANGA_PID, "\"#{manga['id']}\"")
    progress_bar.log "Updated Q#{wikidata_item_for_current_manga[:wikidata_id]} (#{wikidata_item_for_current_manga[:name]}) with AniList ID of #{manga['id']}."
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
  end
  sleep 2

  progress_bar.increment
end

puts "#{manga_that_can_be_matched} manga matched based on MAL ID."

progress_bar.finish unless progress_bar.finished?
