# frozen_string_literal: true

###
# Script to take a list of wikidata items and check the Steam page to see if
# it's an early access game. If it is, check the publication date on Wikidata
# and ensure that it has an 'early access' qualifier.
#
# In the mass-import of games from Steam, we had a bug that caused the early
# access qualifier to not be added on publication date statements. This script
# is intended to fix that mistake.
#
# ENVIRONMENT VARIABLES:
#
# WIKIDATA_USERNAME: username for Wikidata account
# WIKIDATA_PASSWORD: password for Wikidata account
###

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

# Returns a list of Wikidata items with a Steam AppID, publication date,
# and no early access qualifier on the publication date.
def query
  <<-SPARQL
    SELECT ?item ?itemLabel ?steamAppId {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P1733 ?steamAppId. # items with a Steam App ID.
      ?item p:P577 ?statement.
      ?statement ps:P577 ?publicationDate.
      FILTER NOT EXISTS { ?statement pq:P3831 ?hasRole. } # Get rid of anything with a role qualifier on the publication date.
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL
end

wikidata_client = MediawikiApi::Wikidata::WikidataClient.new 'https://www.wikidata.org/w/api.php'
wikidata_client.log_in(ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"])

sparql_client = SPARQL::Client.new(
  "https://query.wikidata.org/sparql",
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
)

# Get the response from the Wikidata query.
rows = sparql_client.query(query)

# We need a list of Wikidata IDs to check, since this script is intended to fix
# a bug in a previous script, so we only need to run it against specific items.
qids_to_check = File.read('./qids.txt').split("\n").filter { |qid| qid != '' }.compact

rows = rows.filter do |row|
  qids_to_check.include?(row.to_h[:item].to_s.gsub('http://www.wikidata.org/entity/', ''))
end

puts "Got #{rows.count} items."

progress_bar = ProgressBar.create(
  total: rows.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

# Iterate through every item returned by the SPARQL query, filtered down based on the QIDs in the list.
rows.each_with_index do |row, index|
  progress_bar.increment

  row = row.to_h
  # Get the English label for the item.
  name = row[:itemLabel].to_s
  # Get the item ID.
  item = row[:item].to_s.gsub('http://www.wikidata.org/entity/', '')

  existing_claims = WikidataHelper.get_claims(entity: item, property: 'P577')
  if existing_claims == {}
    progress_bar.log "This item has no publication date."
    next
  end

  # Skip if there's more than one publication date on the item, we can't really handle that right now.
  if existing_claims['P577'].count > 1
    progress_bar.log 'The item has more than one publication date.'
    next
  end

  # Sleep to avoid Steam rate limits
  sleep 1

  # Get the Steam AppID
  steam_appid = row[:steamAppId]
  steam_url = "https://store.steampowered.com/app/#{steam_appid}"

  uri = URI("https://store.steampowered.com/api/appdetails/?appids=#{steam_appid}")
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = 'Valve/Steam HTTP Client 1.0 (tenfoot)'
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) {|http|
    http.request(request)
  }

  # Parse the JSON response to get the game's 'genres', which includes whether the game is early access.
  response = JSON.parse(response.body)
  genres = response&.dig(response&.keys&.first, 'data', 'genres')&.map { |g| g['description'] }

  # If genres is nil, that means there was no genres data in the response
  # from Steam, which suggests the Steam App ID was wrong, Steam has
  # started rate limiting us, or the Steam page doesn't have this info.
  if genres.nil?
    # If no categories are found, print a failure message and the Steam URL.
    progress_bar.log "Steam request failed for #{name}."
    progress_bar.log steam_url
    progress_bar.log ''
    next
  end

  unless genres.include?('Early Access')
    progress_bar.log "Game is not early access."
    progress_bar.log ''
    next
  end

  progress_bar.log "Adding early access to publication date."
  progress_bar.log "#{row.to_h[:item].to_s}"

  # Get the claim ID for the publication date.
  claim_id = existing_claims.dig('P577', 0, 'id')

  # Add 'has role: early access' qualifier to the publication date.
  early_access_qualifier = { "entity-type": "item", "numeric-id": 17042291, "id": "Q17042291" }

  # Try to set the qualifier for early access, report an error if it fails for any reason.
  begin
    wikidata_client.set_qualifier(claim_id.to_s, 'value', 'P3831', early_access_qualifier.to_json)
  rescue => error
    progress_bar.log "ERROR: #{error}"
  end

  # Sleep for 2 seconds between edits to make sure we don't hit the Wikidata
  # or Steam rate limits.
  progress_bar.log ''
  sleep(2)
end

progress_bar.finish unless progress_bar.finished?
