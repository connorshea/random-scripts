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
  game = key_hash[:pcgw_id].to_s

  platforms = PcgwHelper.get_attributes_for_game(game, %i[platforms])
  next unless platforms.respond_to?(:values) # Skip if the platforms object returned is invalid, that way we don't error.
  platforms = platforms.values[0]
  if platforms.empty?
    progress_bar.log "No platforms found for #{key_hash[:itemLabel].to_s}."
    next
  end

  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')

  platforms.each do |platform|
    if platform == 'Mac OS'
      progress_bar.log 'Mac OS, skipping.'
      next
    end
    progress_bar.log "Adding #{platform} to #{key_hash[:itemLabel]}"
    wikidata_platform_identifier = {
      "entity-type": "item",
      "numeric-id": platform_wikidata_ids[platform.to_sym],
      "id": "Q#{platform_wikidata_ids[platform.to_sym]}"
    }

    claim = wikidata_client.create_claim(wikidata_id, "value", "P400", wikidata_platform_identifier.to_json)
  end
end

progress_bar.finish unless progress_bar.finished?
