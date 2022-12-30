# frozen_string_literal: true

# ENVIRONMENT VARIABLES:
#
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
end

require 'sparql/client'
require 'json'
require 'open-uri'
require 'net/http'
require 'nokogiri'
require 'mediawiki_api'
require 'mediawiki_api/wikidata/wikidata_client'
require_relative '../wikidata_helper.rb'
require_relative '../wikidata_importer.rb'

include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

MT_ZONE_PROPERTY = 'P11400'.freeze

# Returns a list of Wikidata items with a GiantBomb ID and no microtransaction.zone ID.
def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?giantBombId {
      ?item wdt:P31 wd:Q7889; # instance of video game
        wdt:P5247 ?giantBombId. # items with a GiantBomb ID.
      FILTER NOT EXISTS { ?item wdt:P11400 ?microtransactionZoneId . } # with no microtransaction zone ID
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

puts "Got #{rows.count} items."

progress_bar = ProgressBar.create(
  total: rows.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

# Iterate through every item returned by the SPARQL query.
rows.each_with_index do |row, index|
  progress_bar.log ''

  row = row.to_h
  # Get the English label for the item.
  name = row[:itemLabel].to_s
  # Get the item ID.
  item = row[:item].to_s.gsub('http://www.wikidata.org/entity/', '')

  # Check for an existing MT Zone claim on the Wikidata item.
  existing_claims = WikidataHelper.get_claims(entity: item, property: MT_ZONE_PROPERTY)
  if existing_claims != {} && !existing_claims.nil?
    progress_bar.log "SKIP: This item already has a MT Zone ID."
    progress_bar.increment
    next
  end

  # Get the GiantBomb ID
  giant_bomb_id = row[:giantBombId].to_s
  mt_zone_id = giant_bomb_id.split('3030-').last

  uri = URI("https://microtransaction.zone/Game?id=#{mt_zone_id}")
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = 'Ruby Wikidata importer'
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) {|http|
    http.request(request)
  }

  # Grab the HTML contents of the page.
  doc = Nokogiri::HTML(response.body)

  # Returns a value like "Super Mario Odyssey - MICROTRANSACTION.ZONE", and we
  # only want "Super Mario Odyssey", so we're going to cut off the last part
  # after the hyphen.
  game_title_on_mt_zone = doc.at_css('title').text.split(' - ')[0...-1].join(' - ')

  # Compare the MT Zone name with the name on Wikidata to ensure we don't
  # accidentally apply the wrong ID to the Wikidata item.
  unless WikidataImporter.games_have_same_name?(name, game_title_on_mt_zone)
    progress_bar.log("SKIP: The name on Wikidata (#{name}) does not match the name on MT Zone (#{game_title_on_mt_zone}). Skipping")
    progress_bar.increment
    sleep 2
    next
  end

  progress_bar.log "Adding MT Zone ID #{mt_zone_id} to #{name}."
  progress_bar.log "#{row[:item].to_s}"

  # Create the Microtransaction Zone ID statement, and catch an error if it occurs.
  begin
    # NOTE: we may want/be able to just pass this as an integer, no quotation marks.
    wikidata_client.create_claim(item, "value", MT_ZONE_PROPERTY, "\"#{mt_zone_id}\"")
  rescue => error
    progress_bar.log "ERROR: #{error}"
  end

  # Sleep for 2 seconds between edits to make sure we don't hit the Wikidata
  # rate limits or put too much pressure on MT Zone.
  sleep(2)

  progress_bar.increment
end

progress_bar.finish unless progress_bar.finished?
