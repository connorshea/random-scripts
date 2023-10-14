# frozen_string_literal: true

###
# Script to add Nintendo Switch platform to items with eShop IDs and a Switch
# qualifier.
#
# Environment variables:
# - WIKIDATA_USERNAME: Username for Wikidata bot account.
# - WIKIDATA_PASSWORD: Password for Wikidata bot account.
###

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

require 'sparql/client'
require_relative '../wikidata_helper.rb'
include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

ENDPOINT = "https://query.wikidata.org/sparql"

REFERENCE_PROPERTIES = {
  stated_in: 'P248',
  retreived: 'P813',
  eshop_id: 'P8084'
}

# Get all the Wikidata items with eShop IDs and no Nintendo Switch title ID.
def items_with_eshop_id_and_no_switch_platform_query
  <<-SPARQL
    SELECT ?item ?itemLabel ?eshopId WHERE {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P8084 ?eshopId. # with an eShop ID
      ?item p:P8084 ?eshopStatement. # eShop ID statement
      ?eshopStatement pq:P400 wd:Q19610114. # with a platform of Nintendo Switch
      FILTER NOT EXISTS { ?item wdt:P400 wd:Q19610114. } # Get rid of anything with a platform of Switch.
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,en"  }    
    }
  SPARQL
end

client = SPARQL::Client.new(
  ENDPOINT,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+rubyscripts@gmail.com) Ruby 3.1" }
)

items_to_check = client.query(items_with_eshop_id_and_no_switch_platform_query)

wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

items_to_check = items_to_check.filter { |item| item.to_h[:eshopId].to_s.end_with?('switch') }

progress_bar = ProgressBar.create(
  total: items_to_check.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

# Go through each item in the SPARQL response, check if they exist in the Switch title IDs => eShop IDs mapping,
# and then add the Switch title ID if so.
items_to_check.each do |item|
  progress_bar.log '----------------'

  wikidata_id = item.to_h[:item].to_s.sub('http://www.wikidata.org/entity/', '')

  # Make sure the game doesn't already have a Nintendo Switch title ID.
  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P400')
  if existing_claims != {} && !existing_claims.nil?
    if existing_claims['P400'].map { |claim| claim.dig('mainsnak', 'datavalue', 
'value', 'id') }.include?('Q19610114')
      progress_bar.log "SKIP: This item already has a platform statement for Nintendo Switch."
      progress_bar.increment
      next
    end
  end

  begin
    progress_bar.log "Adding Nintendo Switch platform to item '#{wikidata_id}'..."
    claim = wikidata_client.create_claim(
      wikidata_id,
      "value",
      'P400',
      { "entity-type": "item", "numeric-id": 19610114, "id": "Q19610114" }.to_json
    )
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
    next
  end

  claim_id = claim.data.dig('claim', 'id')

  snak = {
    REFERENCE_PROPERTIES[:stated_in] => [
      {
        "snaktype" => "value",
        "property" => REFERENCE_PROPERTIES[:stated_in],
        "datatype" => "wikibase-item",
        "datavalue" => {
          "value" => {
            "entity-type" => "item",
            "numeric-id" => 3070866,
            "id" => "Q3070866"
          },
          "type" => "wikibase-entityid"
        }
      }
    ],
    REFERENCE_PROPERTIES[:eshop_id] => [
      {
        "snaktype" => "value",
        "property" => REFERENCE_PROPERTIES[:eshop_id],
        "datatype" => "external-id",
        "datavalue" => {
          "value" => item.to_h[:eshopId].to_s,
          "type" => "string"
        }
      }
    ],
    REFERENCE_PROPERTIES[:retreived] => [
      {
        "snaktype" => "value",
        "property" => REFERENCE_PROPERTIES[:retreived],
        "datatype" => "time",
        "datavalue" => {
          "value" => {
            "time" => Date.today.strftime("+%Y-%m-%dT%H:%M:%SZ"),
            "timezone" => 0,
            "before" => 0,
            "after" => 0,
            "precision" => 11,
            "calendarmodel" => "http://www.wikidata.org/entity/Q1985727"
          },
          "type" => "time"
        }
      }
    ]
  }

  progress_bar.log 'Adding reference to statement...'
  begin
    wikidata_client.set_reference(claim_id, snak.to_json)
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
  end

  progress_bar.increment

  # To avoid hitting the API rate limit.
  sleep 2
end

progress_bar.finish unless progress_bar.finished?
