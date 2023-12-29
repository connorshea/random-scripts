#####
# Use the IGDB games transformed JSON to get GiantBomb IDs for games and then
# use that information to match IGDB IDs to Wikidata items that already have
# a GiantBomb ID. Then add those IGDB IDs to Wikidata.
#
# ENVIRONMENT VARIABLES:
#
# WIKIDATA_USERNAME: username for Wikidata account
# WIKIDATA_PASSWORD: password for Wikidata account
#####

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'nokogiri'
  gem 'sparql-client', '~> 3.1.0'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'json'
require 'sparql/client'
# For comparing using Levenshtein Distance.
# https://stackoverflow.com/questions/16323571/measure-the-distance-between-two-strings-with-ruby
require "rubygems/text"
require_relative '../wikidata_helper.rb'

include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

def games_have_same_name?(name1, name2)
  name1 = name1.downcase
  name2 = name2.downcase
  return true if name1 == name2

  levenshtein = Class.new.extend(Gem::Text).method(:levenshtein_distance)

  distance = levenshtein.call(name1, name2)
  return true if distance <= 2

  replacements = [
    {
      before: '&',
      after: 'and'
    },
    {
      before: 'deluxe',
      after: ''
    },
    {
      before: ' (video game)',
      after: ''
    },
  ]
  replacements.each do |replacement|
    name1 = name1.gsub(replacement[:before], replacement[:after]).strip
    name2 = name2.gsub(replacement[:before], replacement[:after]).strip
  end

  return true if name1 == name2

  return false
end

# SPARQL query to get all the games on Wikidata that have a GiantBomb ID and no IGDB ID.
def sparql_query
  return <<-SPARQL
    SELECT ?item ?itemLabel (SAMPLE(?gbId) as ?gbId) WHERE {
      ?item wdt:P31 wd:Q7889; # instance of video game
      wdt:P5247 ?gbId. # items with a GiantBomb ID.
      FILTER NOT EXISTS { ?item wdt:P5794 ?igdbId. } # with no IGDB ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE],en". }
    }
    GROUP BY ?item ?itemLabel
  SPARQL
end

# Get the Wikidata rows from the Wikidata SPARQL query
def wikidata_rows
  sparql_client = SPARQL::Client.new(
    "https://query.wikidata.org/sparql",
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
  )

  # Get the response from the Wikidata query.
  rows = sparql_client.query(sparql_query)

  rows.map! do |row|
    key_hash = row.to_h
    {
      name: key_hash[:itemLabel].to_s,
      wikidata_id: key_hash[:item].to_s.sub('http://www.wikidata.org/entity/Q', ''),
      giantbomb_id: key_hash[:gbId].to_s
    }
  end

  rows
end

# Create and return an authenticated Wikidata Client.
def wikidata_client
  client = MediawikiApi::Wikidata::WikidataClient.new('https://www.wikidata.org/w/api.php')
  client.log_in(ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"])
  client
end

IGDB_PROPERTY = 'P5794'
GIANTBOMB_QID = 1657282

REFERENCE_PROPERTIES = {
  matched_by_identifier_from: 'P11797',
  retreived: 'P813',
  giantbomb_id: 'P5247'
}

igdb_games = JSON.load(File.open(File.join(File.dirname(__FILE__), 'igdb_games-transformed.json'))).dig('games').map do |game|
  game.transform_keys(&:to_sym)
end

puts "#{igdb_games.count} games!"

# Filter down to only the IGDB games that have GiantBomb IDs.
igdb_games.filter! { |igdb_game| !igdb_game[:giantbomb_id].nil? }

rows = wikidata_rows

giantbomb_ids_from_wikidata = rows.map { |row| row[:giantbomb_id] }

# Filter down to IGDB Games where the GiantBomb ID exists for an item in
# Wikidata, where that Wikidata item has no IGDB ID. Essentially, get the
# intersection of the SPARQL query and the IGDB games with GiantBomb IDs.
igdb_games.filter! do |igdb_game|
  giantbomb_ids_from_wikidata.include?(igdb_game[:giantbomb_id])
end

puts "There are #{igdb_games.count} items in Wikidata with a matching GiantBomb ID from IGDB and no corresponding IGDB ID."

progress_bar = ProgressBar.create(
  total: igdb_games.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

client = wikidata_client
igdb_ids_added_count = 0
edited_wikidata_ids = []

# Iterate over all the IGDB Games and find the records that match a Wikidata
# item. Then add the IGDB ID to the given item in Wikidata.
igdb_games.each do |igdb_game|
  progress_bar.log ''
  progress_bar.log "GAME: #{igdb_game[:name]}"

  matching_wikidata_item = rows.find { |row| row[:giantbomb_id] == igdb_game[:giantbomb_id] }

  if matching_wikidata_item.nil?
    progress_bar.log 'SKIP: No matching wikidata item found.'
    progress_bar.increment
    next
  end

  # Filter out games that don't have the same name on IGDB and Wikidata.
  # This is to prevent issues with false-positive matches due to incorrect GiantBomb IDs.
  unless games_have_same_name?(igdb_game[:name], matching_wikidata_item[:name])
    progress_bar.log 'SKIP: No matching wikidata items found.'
    progress_bar.increment
    next
  end

  # Skip if the wikidata item has already been edited in the current run of this script.
  if edited_wikidata_ids.include?(matching_wikidata_item[:wikidata_id])
    progress_bar.log "SKIP: This Wikidata item has already been edited. IGDB Slug: #{igdb_game[:slug]}"
    progress_bar.increment
    next
  end

  # Check for an existing IGDB claim on the Wikidata item.
  existing_claims = WikidataHelper.get_claims(entity: matching_wikidata_item[:wikidata_id], property: IGDB_PROPERTY)
  if existing_claims != {} && !existing_claims.nil?
    progress_bar.log "SKIP: This item already has an IGDB ID."
    progress_bar.increment
    next
  end

  # Add a sleep to avoid hitting the rate limit.
  sleep 1

  # Add the IGDB ID to the relevant Wikidata item.
  claim = client.create_claim("Q#{matching_wikidata_item[:wikidata_id]}", "value", IGDB_PROPERTY, "\"#{igdb_game[:slug]}\"")
  claim_id = claim.data.dig('claim', 'id')

  snak = {
    REFERENCE_PROPERTIES[:matched_by_identifier_from] => [
      {
        "snaktype" => "value",
        "property" => REFERENCE_PROPERTIES[:matched_by_identifier_from],
        "datatype" => "wikibase-item",
        "datavalue" => {
          "value" => {
            "entity-type" => "item",
            "numeric-id" => GIANTBOMB_QID,
            "id" => "Q#{GIANTBOMB_QID}"
          },
          "type" => "wikibase-entityid"
        }
      }
    ],
    REFERENCE_PROPERTIES[:giantbomb_id] => [
      {
        "snaktype" => "value",
        "property" => REFERENCE_PROPERTIES[:giantbomb_id],
        "datatype" => "external-id",
        "datavalue" => {
          "value" => matching_wikidata_item[:giantbomb_id].to_s,
          "type" => "string"
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
    ]
  }

  progress_bar.log 'Adding reference to statement...'
  begin
    wikidata_client.set_reference(claim_id, snak.to_json)
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
  end

  # Add the ID to the array of Wikidata IDs we've edited.
  edited_wikidata_ids << matching_wikidata_item[:wikidata_id]

  progress_bar.log "DONE: Added IGDB ID on Q#{matching_wikidata_item[:wikidata_id]}"
  igdb_ids_added_count += 1
  progress_bar.increment
end

progress_bar.finish unless progress_bar.finished?
puts "#{igdb_ids_added_count} IGDB IDs added to Wikidata!"
