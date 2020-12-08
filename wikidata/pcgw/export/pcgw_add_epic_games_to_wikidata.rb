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
      FILTER NOT EXISTS { ?item wdt:P6278 ?epic_store_id . } # and no Epic Games Store ID
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

all_pages = PcgwHelper.get_all_pages_with_property(:epic_games_store_id)
pcgw_games = all_pages.map do |page|
  epic_games_store_ids = page["printouts"][PcgwHelper.get_pcgw_attr_name(:epic_games_store_id)]
  nil if epic_games_store_ids.empty?
  {
    name: page["name"],
    pcgw_id: page["fullurl"].sub('https://www.pcgamingwiki.com/wiki/', ''),
    epic_games_store_id: epic_games_store_ids[0]
  }
end

pcgw_games.filter! { |game| !game.nil? }

# Create an array of PCGW IDs that have Epic Games Store IDs.
pcgw_ids = pcgw_games.map { |game| game[:pcgw_id] }

rows.each do |row|
  progress_bar.increment

  key_hash = row.to_h
  game = key_hash[:pcgw_id].to_s
  next unless pcgw_ids.include?(game)

  begin
    game_with_pcgw_id = pcgw_games.find { |pcgw_game| pcgw_game[:pcgw_id] == game }
    if game_with_pcgw_id.nil?
      progress_bar.log "The PCGW ID for #{key_hash[:itemLabel].to_s} doesn't match any PCGW IDs with associated Epic Games Store IDs."
      next
    end
    epic_games_store_id = game_with_pcgw_id[:epic_games_store_id]
  rescue NoMethodError => e
    progress_bar.log "#{e}"
    next
  end

  if epic_games_store_id.nil?
    progress_bar.log "No Epic Games Store ID found for #{key_hash[:itemLabel].to_s}."
    next
  end

  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')

  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P6278')
  if existing_claims != {}
    progress_bar.log "This item already has a Epic Games Store ID."
    next
  end

  progress_bar.log "Adding #{epic_games_store_id} to #{key_hash[:itemLabel]}"

  begin
    progress_bar.log epic_games_store_id.inspect if ENV['DEBUG']
    claim = wikidata_client.create_claim(wikidata_id, "value", "P6278", "\"#{epic_games_store_id}\"")
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
  end
  # claim_id = claim.data.dig('claim', 'id')
end

progress_bar.finish unless progress_bar.finished?