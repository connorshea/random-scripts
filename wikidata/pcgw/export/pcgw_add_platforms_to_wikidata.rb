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
require_relative '../../wikidata_bot_client.rb'

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
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (https://github.com/connorshea/random-scripts) Ruby 3.1" }
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

rows.each do |row|
  progress_bar.increment
  key_hash = row.to_h
  game = key_hash[:pcgw_id].to_s

  platforms = PcgwHelper.get_attributes_for_game(game, %i[platforms])
  next unless platforms.respond_to?(:values) # Skip if the platforms object returned is invalid, that way we don't error.
  platforms = platforms.values[0]
  if platforms.nil? || platforms.empty?
    progress_bar.log "No platforms found for #{key_hash[:itemLabel].to_s}."
    next
  end

  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')

  platforms.select! { |platform| platform_wikidata_ids.keys.include?(platform) }
  next if platforms.empty?

  reference_snaks = {
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

  # Add all the platform statements, each with its reference, in a single edit.
  statements = platforms.map do |platform|
    WikidataBotClient.statement(
      property: 'P400',
      datavalue: WikidataBotClient.item_value(platform_wikidata_ids[platform.to_sym]),
      references: [reference_snaks]
    )
  end

  progress_bar.log "Adding #{platforms.join(', ')} to #{key_hash[:itemLabel]}"
  begin
    wikidata_client.add_statements(wikidata_id, statements)
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
  end
  sleep 1
end

progress_bar.finish unless progress_bar.finished?
