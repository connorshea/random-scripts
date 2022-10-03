# frozen_string_literal: true

# Script to add Nintendo Switch title IDs to items.
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'nokogiri'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'json'
require 'sparql/client'
require 'open-uri'
require_relative '../wikidata_helper.rb'
include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

ENDPOINT = "https://query.wikidata.org/sparql"

### Load the Nintendo Switch Title IDs Dump JSON
switch_titles_dump = JSON.parse(File.read('wikidata/eshop/switch-titles-with-eshop-ids.json'))

# Get all the Wikidata items with eShop IDs and no Nintendo Switch title ID.
def items_with_eshop_id_and_no_switch_title_id_query
  <<-SPARQL
    SELECT ?item ?itemLabel ?eshopId WHERE
    {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P8084 ?eshopId. # with an eShop ID
      FILTER NOT EXISTS { ?item wdt:P11072 ?switchTitleId . } # and no Nintendo Switch title ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL
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

client = SPARQL::Client.new(
  ENDPOINT,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+rubyscripts@gmail.com) Ruby 3.1" }
)

items_with_eshop_id_and_no_switch_title_id = client.query(items_with_eshop_id_and_no_switch_title_id_query)

wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

items_with_eshop_id_and_no_switch_title_id = items_with_eshop_id_and_no_switch_title_id.filter { |item| item.to_h[:eshopId].to_s.end_with?('switch') }

progress_bar = ProgressBar.create(
  total: items_with_eshop_id_and_no_switch_title_id.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

eshop_ids_in_switch_titles_dump = switch_titles_dump.map { |title_blob| title_blob['eshop_id'] }

# Go through each item in the SPARQL response, check if they exist in the Switch title IDs => eShop IDs mapping,
# and then add the Switch title ID if so.
items_with_eshop_id_and_no_switch_title_id.each do |item|
  progress_bar.log '----------------'

  item_eshop_id = item.to_h[:eshopId].to_s

  # If the eShop ID cannot be found in the list 
  unless eshop_ids_in_switch_titles_dump.include?(item_eshop_id)
    progress_bar.log "SKIP: eShop ID '#{item_eshop_id}' cannot be found in the Nintendo Switch title IDs dump."
    progress_bar.increment
    next
  end

  switch_title = switch_titles_dump.find { |title_blob| title_blob['eshop_id'] == item_eshop_id }
  switch_title_id = switch_title['switch_title_id']

  unless games_have_same_name?(item.to_h[:itemLabel].to_s, switch_title['name'])
    progress_bar.log "SKIP: Name in Wikidata ('#{item.to_h[:itemLabel].to_s}') differs from name in Switch Title IDs dump ('#{switch_title['name']}')."
    progress_bar.increment
    next
  end

  wikidata_id = item.to_h[:item].to_s.sub('http://www.wikidata.org/entity/Q', '')

  # Make sure the game doesn't already have a Nintendo Switch title ID.
  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P11072')
  if existing_claims != {} && !existing_claims.nil?
    progress_bar.log "SKIP: This item already has a Nintendo Switch title ID."
    progress_bar.increment
    next
  end

  begin
    progress_bar.log "Adding Switch Title ID of '#{switch_title_id}' to item '#{wikidata_id}' with eShop ID '#{item_eshop_id}'..."
    claim = wikidata_client.create_claim(
      "Q#{wikidata_id}",
      "value",
      'P11072',
      "\"#{switch_title_id}\""
    )
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
    next
  end

  progress_bar.increment

  # To avoid hitting the API rate limit.
  sleep 1
end

progress_bar.finish unless progress_bar.finished?
