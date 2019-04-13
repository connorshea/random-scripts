# frozen_string_literal: true

require 'mediawiki_api'
require 'mediawiki_api/wikidata/wikidata_client'
require 'sparql/client'
require 'json'
require_relative './pcgw_helper.rb'
require_relative '../wikidata_helper.rb'

include PcgwHelper
include WikidataHelper

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

client = SPARQL::Client.new(endpoint, :method => :get)

rows = client.query(query)

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

rows.each do |row|
  key_hash = row.to_h
  # puts "#{key_hash[:item].to_s}: #{key_hash[:itemLabel].to_s}"
  game = key_hash[:pcgw_id].to_s
  
  begin
    wine_app_ids = PcgwHelper.get_attributes_for_game(game, %i[wine_app_id]).values[0]
  rescue NoMethodError => e
    puts "#{e}"
    next
  end
  if wine_app_ids.empty?
    puts "No WineHQ App IDs found for #{key_hash[:itemLabel].to_s}."
    next
  end

  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')
  
  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P600')
  if existing_claims != {}
    puts "This item already has a WineHQ App ID."
    next
  end

  puts "Adding #{wine_app_ids[0]} to #{key_hash[:itemLabel]}"

  claim = wikidata_client.create_claim(wikidata_id, "value", "P600", "'#{wine_app_ids[0]}'")
  # claim_id = claim.data.dig('claim', 'id')
end
