# frozen_string_literal: true

#####
# Get PCGamingWiki IDs and import them into Wikidata based on the associated
# Steam ID.
#
# ENVIRONMENT VARIABLES:
#
# WIKIDATA_USERNAME: username for Wikidata account
# WIKIDATA_PASSWORD: password for Wikidata account
#####

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
require_relative './pcgw_helper.rb'
require_relative '../../wikidata_helper.rb'

include PcgwHelper
include WikidataHelper

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

  replacements = [
    {
      before: '&',
      after: 'and'
    }
  ]
  replacements.each do |replacement|
    name1 = name1.gsub(replacement[:before], replacement[:after]).strip
    name2 = name2.gsub(replacement[:before], replacement[:after]).strip
  end

  return true if name1 == name2

  return false
end

endpoint = "https://query.wikidata.org/sparql"

def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?steamAppId WHERE
    {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P1733 ?steamAppId. # with a Steam App ID
      FILTER NOT EXISTS { ?item wdt:P6337 ?pcgwId . } # and no PCGW ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  return sparql
end

def verify_pcgw_url(pcgw_id)
  return false unless pcgw_id.ascii_only?
  url = URI.parse("https://www.pcgamingwiki.com/wiki/#{pcgw_id}")
  req = Net::HTTP.new(url.host, url.port)
  req.use_ssl = true
  res = req.request_head(url.path)
  if res.code == "200"
    return true
  elsif res.code == "404"
    return false
  else
    return false
  end
end

STEAM_QID = 337535

REFERENCE_PROPERTIES = {
  matched_by_identifier_from: 'P11797',
  retreived: 'P813',
  steam_app_id: 'P1733'
}

client = SPARQL::Client.new(
  endpoint,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
)

rows = client.query(query)

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

progress_bar = ProgressBar.create(
  total: rows.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

successful_pcgw_id_additions = 0

rows.each do |row|
  # Sleep to avoid hitting the PCGW API a ton.
  sleep 1
  
  key_hash = row.to_h

  steam_app_id = key_hash[:steamAppId].to_s
  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')
  wikidata_item_label = key_hash[:itemLabel].to_s

  progress_bar.log "Checking PCGamingWiki for #{wikidata_item_label} based on Steam App ID..."

  # .tap { |resp| puts resp.inspect if resp.dig('cargoquery').empty? }
  # PCGW API requests can be ratelimited, but I'm not totally sure what the response looks like in that case...
  response = PcgwHelper.pcgw_api_url([:page_name, :steam_app_id], where: "Infobox_game.Steam_AppID HOLDS \"#{steam_app_id}\"").dig('cargoquery')
  if response.empty?
    progress_bar.log "SKIPPING: Nothing was returned by querying PCGW for Steam ID '#{steam_app_id}'."
    progress_bar.increment
    next
  end

  pcgw_game_hash = response.dig(0, 'title')

  # If the Wikidata item and PCGW game don't have the same name, skip this.
  unless games_have_same_name?(pcgw_game_hash['Name'], wikidata_item_label)
    progress_bar.log("SKIPPING: '#{pcgw_game_hash['Name']}' does not match '#{key_hash[:itemLabel].to_s}'.")
    progress_bar.increment
    next
  end

  pcgw_id = pcgw_game_hash['Name'].gsub(' ', '_')
  unless verify_pcgw_url(pcgw_id)
    progress_bar.log("SKIPPING: '#{pcgw_id}' is invalid and could not be resolved to a valid PCGamingWiki page.")
    progress_bar.increment
    next
  end

  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P6337')
  if existing_claims != {}
    progress_bar.log "This item already has a PCGamingWiki ID."
    next
  end

  claim = wikidata_client.create_claim(wikidata_id, "value", "P6337", "\"#{pcgw_id}\"")
  claim_id = claim.data.dig('claim', 'id')

  snak = {
    REFERENCE_PROPERTIES[:matched_by_identifier_from] => [
      {
        "snaktype" => "value",
        "property" => REFERENCE_PROPERTIES[:matched_by_identifier_from],
        "datatype" => "wikibase-item",
        "datavalue" => {
          "value" => {
            "entity-type" => "item",
            "numeric-id" => STEAM_QID,
            "id" => "Q#{STEAM_QID}"
          },
          "type" => "wikibase-entityid"
        }
      }
    ],
    REFERENCE_PROPERTIES[:steam_app_id] => [
      {
        "snaktype" => "value",
        "property" => REFERENCE_PROPERTIES[:steam_app_id],
        "datatype" => "external-id",
        "datavalue" => {
          "value" => steam_app_id,
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

  successful_pcgw_id_additions += 1

  progress_bar.log("SUCCESS: Added PCGW ID '#{pcgw_id}' to Wikidata.")
  progress_bar.increment
end

progress_bar.finish unless progress_bar.finished?
puts "#{successful_pcgw_id_additions} PCGW IDs added to Wikidata."
puts "#{rows.count - successful_pcgw_id_additions} items could not find a match in PCGamingWiki."
