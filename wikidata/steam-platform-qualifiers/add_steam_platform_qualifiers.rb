# frozen_string_literal: true
# Credit to Vetle at PCGamingWiki for sharing a Steam API parsing
# script with me. That served as a basis for this script.
#
# This script adds platform qualifiers to Wikidata items with Steam App IDs
# that don't have qualifiers. For example, see the Steam Application ID
# for Half-Life 2:
# https://www.wikidata.org/wiki/Q193581#P1733
#
# This script:
# - Runs a SPARQL query to get a list of every item on Wikidata with a Steam App ID that's lacking platform qualifiers.
# - Iterates through that list.
# - Gets the platforms for the game from the Steam API.
# - Applies the platform qualifiers depending on the platforms Steam returns.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'sparql/client'
require 'json'
require 'open-uri'
require 'net/http'
require 'mediawiki_api'
require 'mediawiki_api/wikidata/wikidata_client'

# Returns a list of Wikidata items with a Steam AppID and no platform qualifier for it.
def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?appID ?platform WHERE {
      ?item p:P1733 ?statement.
        ?statement ps:P1733 ?appID.
        FILTER NOT EXISTS {?statement pq:P400 ?platform.} # Get rid of anything with a platform qualifier.
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,en"  }
    }
  SPARQL

  sparql
end

# Get claims for the given Wikidata item about the given property.
def get_claims(item:, property:)
  JSON.parse(URI.open("https://www.wikidata.org/w/api.php?action=wbgetclaims&entity=#{item}&property=#{property}&format=json").read)
end

wikidata_client = MediawikiApi::Wikidata::WikidataClient.new 'https://www.wikidata.org/w/api.php'
wikidata_client.log_in(ENV["WIKIDATA_USERNAME"].to_s, ENV["WIKIDATA_PASSWORD"].to_s)

sparql_client = SPARQL::Client.new(
  "https://query.wikidata.org/sparql",
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 2.6" }
)

# Get the response from the Wikidata query.
sparql = query
rows = sparql_client.query(sparql)

# Platform Wikidata IDs. Steam only supports Windows, macOS, and Linux.
platform_wikidata_ids = {
  windows: 1406,
  mac: 14116,
  linux: 388
}

# Platform names for printing.
humanized_platforms = {
  windows: 'Windows',
  mac: 'macOS',
  linux: 'Linux'
}

puts "Got #{rows.count} items."

progress_bar = ProgressBar.create(
  total: rows.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

# Iterate through every item returned by the SPARQL query.
rows.each_with_index do |row, index|
  progress_bar.increment

  # Get the English label for the item.
  name = row.to_h[:itemLabel].to_s
  # Get the item ID.
  item = row.to_h[:item].to_s.gsub('http://www.wikidata.org/entity/', '')
  # Get all claims for the Wikidata item.
  json = get_claims(item: item, property: 'P1733')

  # Filter to the claims specifically about the Steam App ID.
  claims = json.dig('claims', 'P1733').first
  claim_id = claims.dig('id')
  
  current_platforms = []

  # Get the Steam AppID
  steam_appid = claims.dig("mainsnak", "datavalue", "value")
  steam_url = "https://store.steampowered.com/app/#{steam_appid}"

  uri = URI("https://store.steampowered.com/api/appdetails/?appids=#{steam_appid}")
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = 'Valve/Steam HTTP Client 1.0 (tenfoot)'
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) {|http|
    http.request(request)
  }

  # Parse the JSON response to get the game's platforms.
  response = JSON.parse(response.body)
  platforms = response&.dig(response&.keys&.first, 'data', 'platforms')
  # If platforms is nil, that means there was no platforms data in the response
  # from Steam, which suggests either the Steam App ID was wrong or Steam has
  # started rate limiting us.
  if !platforms.nil?
    # Filter the platforms list down to platforms with a true value.
    platforms.select! { |key, value| value == true }
    # Map to symbolized representations of each platform (e.g. :mac instead of 'mac')
    platforms = platforms.keys.map { |key| key.to_sym }

    # Add the humanized representation of each platform to the current_platforms array.
    platforms.each do |platform|
      current_platforms << humanized_platforms[platform]
    end
    # Print the Steam URL and available platforms.
    progress_bar.log steam_url
    progress_bar.log "Available on #{current_platforms.join(', ')}."
  else
    # If no platforms are found, print a failure message and the Steam URL.
    progress_bar.log "Steam request failed for #{name}."
    progress_bar.log steam_url
    progress_bar.log ''
    next
  end

  # Add these qualifiers depending on the platforms listed on the Steam page.
  platform_values = {
    windows: { "entity-type": "item", "numeric-id": platform_wikidata_ids[:windows], "id": "Q#{platform_wikidata_ids[:windows]}" },
    mac: { "entity-type": "item", "numeric-id": platform_wikidata_ids[:mac], "id": "Q#{platform_wikidata_ids[:mac]}" },
    linux: { "entity-type": "item", "numeric-id": platform_wikidata_ids[:linux], "id": "Q#{platform_wikidata_ids[:linux]}" }
  }

  progress_bar.log "Adding #{current_platforms.join(', ')} to #{name}."
  progress_bar.log "#{row.to_h[:item].to_s}"

  # Try to set the qualifier for each platform, report an error if it fails for any reason.
  platforms.each do |platform|
    begin
      wikidata_client.set_qualifier(claim_id.to_s, 'value', 'P400', platform_values[platform].to_json)
    rescue => error
      progress_bar.log "ERROR: #{error}"
    end
  end
  
  # Sleep for 4 seconds between edits to make sure we don't hit the Wikidata
  # rate limit.
  progress_bar.log ''
  sleep(1)
end

progress_bar.finish unless progress_bar.finished?
