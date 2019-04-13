# frozen_string_literal: true

require 'mediawiki_api'
require 'mediawiki_api/wikidata/wikidata_client'
require 'sparql/client'
require 'json'
require_relative './pcgw_helper.rb'
require_relative '../wikidata_helper.rb'
require 'csv'

include PcgwHelper
include WikidataHelper

endpoint = "https://query.wikidata.org/sparql"

def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?pcgw_id WHERE
    {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P6337 ?pcgw_id. # with a PCGW ID
      FILTER NOT EXISTS { ?item wdt:P2725 ?gog_id . } # and no GOG App ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  return sparql
end

client = SPARQL::Client.new(endpoint, :method => :get)

rows = client.query(query)

gog_ids = []
# Parse the GOG DB backup file from https://www.gogdb.org/backups_v2
CSV.foreach(
  File.join(File.dirname(__FILE__), 'gogdb_backup.csv'),
  skip_blanks: true,
  headers: true,
  encoding: 'ISO-8859-1'
) do |csv_row|
  next if csv_row["title"] == "" || csv_row["slug"] == "" || csv_row["product_type"] != "game"
  gog_ids << {
    id: csv_row["id"],
    slug: csv_row["slug"]
  }
end

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

rows.each do |row|
  key_hash = row.to_h
  # puts "#{key_hash[:item].to_s}: #{key_hash[:itemLabel].to_s}"
  game = key_hash[:pcgw_id].to_s
  
  begin
    gog_app_ids = PcgwHelper.get_attributes_for_game(game, %i[gog_app_id]).values[0]
  rescue NoMethodError => e
    puts "#{e}"
    next
  end

  if gog_app_ids.empty?
    puts "No GOG App IDs found for #{key_hash[:itemLabel].to_s}."
    next
  end

  gog_app_id = gog_app_ids[0]

  gog_hash = gog_ids.detect { |gog_id| gog_id[:id].to_i == gog_app_id }

  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')
  
  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P2725')
  if existing_claims != {}
    puts "This item already has a GOG App ID."
    next
  end

  gog_app_value = "game/#{gog_hash[:slug]}"

  puts "Adding #{gog_app_value} to #{key_hash[:itemLabel]}"

  claim = wikidata_client.create_claim(wikidata_id, "value", "P600", "'#{gog_app_value}'")
end
