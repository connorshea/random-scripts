# frozen_string_literal: true

require 'mediawiki_api'
require 'mediawiki_api/wikidata/wikidata_client'
require 'sparql/client'
require 'json'
require_relative './pcgw_helper.rb'

include PcgwHelper

# Doesn't include Mac OS because I don't know which Mac OS is supposed to be
# used for games right now.
platform_wikidata_ids = {
  'Windows': 1406,
  'OS X': 14116,
  'Linux': 388,
  'DOS': 170434
}

endpoint = "https://query.wikidata.org/sparql"

def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?pcgw_id WHERE
    {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P6337 ?pcgw_id. # with a PCGW ID
      FILTER NOT EXISTS { ?item wdt:P400 ?platform . } # with no platforms
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
    LIMIT 50
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
  
  platforms = PcgwHelper.get_attributes_for_game(game, %i[platforms]).values[0]
  if platforms.empty?
    puts "No platforms found."
    next
  end

  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')

  platforms.each do |platform|
    puts "Adding #{platform} to #{key_hash[:itemLabel]}"
    wikidata_platform_identifier = {
      "entity-type": "item",
      "numeric-id": platform_wikidata_ids[platform.to_sym],
      "id": "Q#{platform_wikidata_ids[platform.to_sym]}"
    }

    claim = wikidata_client.create_claim(wikidata_id, "value", "P400", wikidata_platform_identifier.to_json)
    # puts JSON.pretty_generate(claim.data.dig('claim', 'id'))
  end
end
