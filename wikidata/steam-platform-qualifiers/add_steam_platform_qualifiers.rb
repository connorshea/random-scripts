# frozen_string_literal: true

require 'dotenv/load'
require 'sparql/client'
require 'json'
require 'open-uri'
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

def get_claims(item:, property:)
  JSON.parse(URI.open("https://www.wikidata.org/w/api.php?action=wbgetclaims&entity=#{item}&property=#{property}&format=json").read)
end

wikidata_client = MediawikiApi::Wikidata::WikidataClient.new 'https://www.wikidata.org/w/api.php'
wikidata_client.log_in(ENV["WIKIDATA_USERNAME"].to_s, ENV["WIKIDATA_PASSWORD"].to_s)

endpoint = 'https://query.wikidata.org/sparql'
sparql_client = SPARQL::Client.new(endpoint, method: :get)

# Get the response from the Wikidata query.
sparql = query
rows = sparql_client.query(sparql)

platform_wikidata_ids = {
  windows: 1406,
  macos: 14116,
  linux: 388
}

puts "Got #{rows.length} items."

rows.each_with_index do |row, index|
  break if index.positive?

  puts row.to_h.inspect
  item = row.to_h[:item].to_s.gsub('http://www.wikidata.org/entity/', '')
  json = get_claims(item: item, property: 'P1733')

  claims = json.dig('claims', 'P1733').first
  claim_id = claims.dig('id')
  
  # Get the Steam AppID
  steam_appid = claims.dig("mainsnak", "datavalue", "value")
  steam_url = "https://store.steampowered.com/app/#{steamappid}"

  # TODO: Check what platforms its on by scraping Steam.


  # Add these qualifiers depending on the platforms listed on the Steam page.
  platform_values = {
    windows: { "entity-type": "item", "numeric-id": platform_wikidata_ids[:windows], "id": "Q#{platform_wikidata_ids[:windows]}" },
    macos: { "entity-type": "item", "numeric-id": platform_wikidata_ids[:macos], "id": "Q#{platform_wikidata_ids[:macos]}" },
    linux: { "entity-type": "item", "numeric-id": platform_wikidata_ids[:linux], "id": "Q#{platform_wikidata_ids[:linux]}" }
  }

  # placeholder, replace these depending on what the Steam page says.
  platforms = [:windows, :macos, :linux]

  # platforms.each do |platform|
  #   wikidata_client.set_qualifier(claim_id.to_s, 'value', 'P400', platform_values[platform.to_sym].to_json)
  # end
end
