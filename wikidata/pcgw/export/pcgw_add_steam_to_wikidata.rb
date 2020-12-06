# frozen_string_literal: true
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'json'
require 'sparql/client'
require_relative './pcgw_helper.rb'
require_relative '../wikidata_helper.rb'

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
      FILTER NOT EXISTS { ?item wdt:P1733 ?steam_app_id . } # and no Steam App ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  return sparql
end

client = SPARQL::Client.new(
  endpoint,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 2.6" }
)

rows = client.query(query)

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

progress_bar = ProgressBar.create(
  total: rows.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

rows.each do |row|
  progress_bar.increment
  key_hash = row.to_h
  # puts "#{key_hash[:item].to_s}: #{key_hash[:itemLabel].to_s}"
  game = key_hash[:pcgw_id].to_s
  
  begin
    steam_app_ids = PcgwHelper.get_attributes_for_game(game, %i[steam_app_id])
    next if steam_app_ids.length == 0
    steam_app_ids = steam_app_ids.values[0]
  rescue NoMethodError => e
    progress_bar.log "#{e}"
    next
  end
  if steam_app_ids.empty?
    progress_bar.log "No Steam App IDs found for #{key_hash[:itemLabel].to_s}."
    next
  end

  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')

  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P1733')
  if existing_claims != {}
    progress_bar.log "This item already has a Steam App ID."
    next
  end

  progress_bar.log "Adding #{steam_app_ids[0]} to #{key_hash[:itemLabel]}"

  begin
    progress_bar.log steam_app_ids.inspect if ENV['DEBUG']
    claim = wikidata_client.create_claim(wikidata_id, "value", "P1733", "\"#{steam_app_ids[0]}\"")
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
  end
  # claim_id = claim.data.dig('claim', 'id')
end

progress_bar.finish unless progress_bar.finished?
