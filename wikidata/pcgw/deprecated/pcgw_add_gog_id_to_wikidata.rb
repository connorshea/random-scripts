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

require 'sparql/client'
require 'json'
require_relative './pcgw_helper.rb'
require_relative '../../wikidata_helper.rb'
require 'csv'

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
      FILTER NOT EXISTS { ?item wdt:P2725 ?gog_id . } # and no GOG App ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  return sparql
end

# Check if the GOG URL is correct, if it redirects then it's wrong.
def url_exists?(url_string)
  url = URI.parse(url_string)
  req = Net::HTTP.new(url.host, url.port)
  req.use_ssl = true
  path = url.path unless url.path.empty?
  res = req.request_head(path || '/')
  if res.kind_of?(Net::HTTPRedirection)
    return false
  else
    ! %W(4 5).include?(res.code[0]) # Not from 4xx or 5xx families
  end
rescue Errno::ENOENT
  false #false if can't find the server
end

client = SPARQL::Client.new(
  endpoint,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 3.1" }
)

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

rows.each do |row|
  progress_bar.increment
  key_hash = row.to_h
  # puts "#{key_hash[:item].to_s}: #{key_hash[:itemLabel].to_s}"
  game = key_hash[:pcgw_id].to_s
  
  begin
    gog_app_ids = PcgwHelper.get_attributes_for_game(game, %i[gog_app_id]).values[0]
  rescue NoMethodError => e
    progress_bar.log "#{e}"
    next
  end

  if gog_app_ids.empty?
    progress_bar.log "No GOG App IDs found for #{key_hash[:itemLabel].to_s}."
    next
  end

  gog_app_id = gog_app_ids[0]

  gog_hash = gog_ids.detect { |gog_id| gog_id[:id].to_i == gog_app_id }
  next if gog_hash.nil?

  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')
  
  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P2725')
  if existing_claims != {}
    progress_bar.log "This item already has a GOG App ID."
    next
  end

  gog_app_value = "game/#{gog_hash[:slug]}"

  progress_bar.log "Adding #{gog_app_value} to #{key_hash[:itemLabel]}"

  gog_url = "https://www.gog.com/#{gog_app_value}"
  progress_bar.log gog_url
  if url_exists?(gog_url)
    claim = wikidata_client.create_claim(wikidata_id, "value", "P2725", "\"#{gog_app_value}\"")
  else
    progress_bar.log "URL redirects, not adding."
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
