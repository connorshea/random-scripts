# frozen_string_literal: true
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

require 'json'
require 'sparql/client'
require_relative './pcgw_helper.rb'
require_relative '../../wikidata_helper.rb'

include PcgwHelper
include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

endpoint = "https://query.wikidata.org/sparql"

def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?pcgw_id WHERE
    {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P6337 ?pcgw_id. # with a PCGW ID
      FILTER NOT EXISTS { ?item wdt:P600 ?wine_app_id . } # and no Wine App ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  return sparql
end

client = SPARQL::Client.new(
  endpoint,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 3.1" }
)

rows = client.query(query)

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

progress_bar = ProgressBar.create(
  total: rows.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

REFERENCE_PROPERTIES = {
  stated_in: 'P248',
  retreived: 'P813',
  reference_url: 'P854'
}

PCGAMINGWIKI_QID = 17013880

all_pages = PcgwHelper.get_all_pages_with_property(:wine_app_id)
pcgw_games = all_pages.map do |page|
  winehq_ids = page["printouts"][PcgwHelper.get_pcgw_attr_name(:wine_app_id)]
  nil if winehq_ids.empty?
  {
    name: page["name"],
    pcgw_id: page["fullurl"].sub('https://www.pcgamingwiki.com/wiki/', ''),
    winehq_id: winehq_ids[0]
  }
end

pcgw_games.filter! { |game| !game.nil? }

# Create an array of PCGW IDs that have WineHQ IDs.
pcgw_ids = pcgw_games.map { |game| game[:pcgw_id] }

rows.each do |row|
  progress_bar.increment

  key_hash = row.to_h
  game = key_hash[:pcgw_id].to_s
  next unless pcgw_ids.include?(game)
  
  begin
    wine_app_ids = PcgwHelper.get_attributes_for_game(game, %i[wine_app_id])
    next if wine_app_ids.length == 0
    wine_app_ids = wine_app_ids.values[0]
  rescue NoMethodError => e
    progress_bar.log "#{e}"
    next
  end

  if wine_app_ids.empty?
    progress_bar.log "No WineHQ App IDs found for #{key_hash[:itemLabel].to_s}."
    next
  end

  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')
  
  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P600')
  if existing_claims != {}
    progress_bar.log "This item already has a WineHQ App ID."
    next
  end

  progress_bar.log "Adding #{wine_app_ids[0]} to #{key_hash[:itemLabel]}"

  begin
    progress_bar.log wine_app_ids.inspect if ENV['DEBUG']
    claim = wikidata_client.create_claim(wikidata_id, "value", "P600", "\"#{wine_app_ids[0]}\"")
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
    next
  end

  # Get the claim ID returned from the create_claim method.
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
            "numeric-id" => PCGAMINGWIKI_QID,
            "id" => "Q#{PCGAMINGWIKI_QID}"
          },
          "type" => "wikibase-entityid"
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
    ],
    REFERENCE_PROPERTIES[:reference_url] => [
      {
        "snaktype" => "value",
        "property" => REFERENCE_PROPERTIES[:reference_url],
        "datatype" => "url",
        "datavalue" => {
          "value" => "https://www.pcgamingwiki.com/wiki/#{key_hash[:pcgw_id].to_s}",
          "type" => "string"
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
  sleep 1
end

progress_bar.finish unless progress_bar.finished?
