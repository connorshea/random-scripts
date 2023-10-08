# frozen_string_literal: true

# Import StrategyWiki IDs into Wikidata from PCGamingWiki's API, complete with
# adding references for statements.
#
# Environment variables:
# - WIKIDATA_USERNAME: Username for Wikidata bot account.
# - WIKIDATA_PASSWORD: Password for Wikidata bot account.

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

require 'json'
require 'sparql/client'
require_relative './pcgw_helper.rb'
require_relative '../../wikidata_helper.rb'

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
      FILTER NOT EXISTS { ?item wdt:P9075 ?strategy_wiki_id . } # and no StrategyWiki ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  return sparql
end

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

REFERENCE_PROPERTIES = {
  stated_in: 'P248',
  retreived: 'P813',
  reference_url: 'P854'
}

PCGAMINGWIKI_QID = 17013880

# Need to use wbsetreference API here. The JSON snak input for adding the
# reference URL, stated in, and retreived values looks like this, it is
# horrendous:
#
# ```json
# {
#   "P248": [
#     {
#       "snaktype": "value",
#       "property": "P248",
#       "datatype": "wikibase-item",
#       "datavalue": {
#         "value": {
#           "entity-type": "item",
#           "numeric-id": 17013880,
#           "id": "Q17013880"
#         },
#         "type": "wikibase-entityid"
#       }
#     }
#   ],
#   "P813": [
#     {
#       "snaktype": "value",
#       "property": "P813",
#       "datatype": "time",
#       "datavalue": {
#         "value": {
#           "time": "+2021-02-06T00:00:00Z",
#           "timezone": 0,
#           "before": 0,
#           "after": 0,
#           "precision": 11,
#           "calendarmodel": "http://www.wikidata.org/entity/Q1985727"
#         },
#         "type": "time"
#       }
#     }
#   ],
#   "P854": [
#     {
#       "snaktype": "value",
#       "property": "P854",
#       "datatype": "url",
#       "datavalue": {
#         "value": "https://www.pcgamingwiki.com/wiki/De_Blob",
#         "type": "string"
#       }
#     }
#   ]
# }
# ```

rows.each do |row|
  progress_bar.increment

  key_hash = row.to_h
  game = key_hash[:pcgw_id].to_s

  begin
    strategy_wiki_ids = PcgwHelper.get_attributes_for_game(game, %i[strategy_wiki_id])
    next if strategy_wiki_ids.length == 0
    sleep 1
    strategy_wiki_ids = strategy_wiki_ids.values[0]
  rescue NoMethodError => e
    progress_bar.log "#{e}"
    next
  end

  if strategy_wiki_ids.empty?
    progress_bar.log "No StrategyWiki IDs found for #{key_hash[:itemLabel].to_s}."
    next
  end

  wikidata_id = key_hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')

  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P9075')
  if existing_claims != {}
    progress_bar.log "This item already has a StrategyWiki ID."
    next
  end

  strategy_wiki_id = strategy_wiki_ids.first.gsub(' ', '_')
  progress_bar.log "Adding #{strategy_wiki_id} to #{key_hash[:itemLabel]}"

  begin
    progress_bar.log strategy_wiki_ids.inspect if ENV['DEBUG']
    claim = wikidata_client.create_claim(wikidata_id, "value", "P9075", "\"#{strategy_wiki_id}\"")
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
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
