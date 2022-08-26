# frozen_string_literal: true

# Script to add ESRB ID Qualifiers to items.
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'nokogiri'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'json'
require 'sparql/client'
require 'open-uri'
require_relative '../wikidata_helper.rb'
include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

ENDPOINT = "https://query.wikidata.org/sparql"

# Hash of Platform names and their Wikidata QIDs.
WIKIDATA_PLATFORMS = {
  "Windows": 1406,
  "Windows PC": 1406,
  "PlayStation 2": 10680,
  "iOS": 48493,
  "Commodore 64": 99775,
  "Disk Operating System": 170434,
  "macOS": 14116,
  "PlayStation 3": 10683,
  "Xbox 360": 48263,
  "Nintendo DS": 170323,
  "DS": 170323,
  "Super Nintendo Entertainment System": 183259,
  "Super Nintendo": 183259,
  "Amiga": 100047,
  "PlayStation": 10677,
  "PlayStation/PS one": 10677,
  "Android": 94,
  "Wii": 8079,
  "Wii U": 56942,
  "PlayStation 4": 5014725,
  "Nintendo Entertainment System": 172742,
  "arcade game machine": 192851,
  "Linux": 388,
  "Sega Mega Drive": 10676,
  "Xbox": 132020,
  "PSP": 170325,
  "Nintendo Game Boy": 186437,
  "Game Boy Color": 203992,
  "Game Boy Advance": 188642,
  "Atari ST": 627302,
  "GameCube": 182172,
  "Xbox One": 13361286,
  "PS Vita": 188808,
  "Nintendo 64": 184839,
  "Dreamcast": 184198,
  "Sega Dreamcast": 184198,
  "Nintendo Switch": 19610114,
  "Xbox Series": 98973368,
  "PlayStation 5": 63184502,
  "Nintendo 3DS": 203597,
  "Stadia": 60309635,
  "Virtual Boy": 164651,
  "Sega Saturn": 200912,
  "Sega Genesis": 10676,
  "Genesis": 10676,
  "Game Gear": 751719,
  "Atari Jaguar": 650601
}.freeze

# Properties
ESRB_GAME_ID = 'P8303'
SUBJECT_NAMED_AS = 'P1810'
PLATFORM = 'P400'
ESRB_RATING = 'P852'
ESRB_INTERACTIVE_ELEMENTS_PID = 'P8428'
CONTENT_DESCRIPTOR_PID = 'P7367'

# Items
ESRB_RATINGS_DATABASE = 105295303

### Load the ESRB Dump JSON
esrb_dump = JSON.parse(File.read('wikidata/esrb/esrb_dump.json'))

PLATFORM_MAPPING = {
  'Windows PC' => 'Windows',
  'PlayStation/PS one' => 'PlayStation'
}.freeze

REFERENCE_PROPERTIES = {
  stated_in: 'P248',
  retreived: 'P813',
  reference_url: 'P854'
}

# Clean up the data a bit
esrb_dump.map! do |esrb_game|
  # Remove copyright symbols and other noise.
  title = esrb_game['title'].gsub(/®|©|™/, '').strip

  # Change the platform names for platforms with weird names in the ESRB Database.
  platforms = esrb_game['platforms'].split(', ').map do |platform|
    if PLATFORM_MAPPING.key?(platform)
      PLATFORM_MAPPING[platform]
    else
      platform
    end
  end.uniq

  descriptors = esrb_game['descriptors'].split(', ')
  descriptors = [] if descriptors == ['No Descriptors']

  interactive_elements = esrb_game['interactive_elements'].map { |elem| elem['name'] }

  OpenStruct.new({
    esrb_id: esrb_game['certificateId'],
    title: title,
    publisher: esrb_game['publisher'],
    rating: esrb_game['rating'],
    platforms: platforms,
    descriptors: descriptors,
    interactive_elements: interactive_elements
  })
end

# Get all the Wikidata items with ESRB game IDs and no qualifiers for it.
#
# Some of these have "unknown value" set, and I'm not sure how to get rid of them.
# It'll have a value like this for the ESRB game ID if it's "unknown value":
# `<http://www.wikidata.org/.well-known/genid/f8296fb7b964d7c179cb7499ba719b55>`
def items_with_esrb_id_and_no_qualifiers_query
  <<-SPARQL
    SELECT DISTINCT ?item ?itemLabel ?esrbId WHERE {
      OPTIONAL {
        ?item p:P8303 ?statement. # Get the statement of the ESRB game ID
        ?statement ps:P8303 ?esrbId. # Get the actual ESRB game ID
        FILTER(NOT EXISTS { ?statement pq:P400 ?platform. }) # Filter out items where the ESRB game ID has platform qualifiers
        FILTER(NOT EXISTS { ?statement pq:P1810 ?subject_stated_as. }) # Filter out items where the ESRB game ID has 'subjected stated as' qualifiers
      }
      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE]". }
    }
  SPARQL
end

# Generate qualifiers for an ESRB rating claim.
def generate_rating_qualifier_snak(game, progress_bar)
  snak = {
    CONTENT_DESCRIPTOR_PID => [],
    ESRB_INTERACTIVE_ELEMENTS_PID => []
  }

  game.descriptors.each do |descriptor|
    unless CONTENT_DESCRIPTORS.keys.map(&:to_s).include?(descriptor)
      progress_bar.log "'#{descriptor}' could not be found in the list of content descriptor QIDs."
      next
    end

    snak[CONTENT_DESCRIPTOR_PID] << {
      "entity-type" => "item",
      "numeric-id" => CONTENT_DESCRIPTORS[descriptor.to_sym],
      "id" => "Q#{CONTENT_DESCRIPTORS[descriptor.to_sym]}"
    }
  end

  game.interactive_elements.each do |interactive_elem|
    unless INTERACTIVE_ELEMENTS.keys.map(&:to_s).include?(interactive_elem)
      progress_bar.log "'#{interactive_elem}' could not be found in the list of interactive elements QIDs."
      next
    end

    snak[ESRB_INTERACTIVE_ELEMENTS_PID] << {
      "entity-type" => "item",
      "numeric-id" => INTERACTIVE_ELEMENTS[interactive_elem.to_sym],
      "id" => "Q#{INTERACTIVE_ELEMENTS[interactive_elem.to_sym]}"
    }
  end

  return snak
end

client = SPARQL::Client.new(
  ENDPOINT,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+rubyscripts@gmail.com) Ruby 3.1" }
)

items_with_esrb_id_and_no_qualifiers = client.query(items_with_esrb_id_and_no_qualifiers_query)

wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

progress_bar = ProgressBar.create(
  total: items_with_esrb_id_and_no_qualifiers.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

# Go through each item in the SPARQL response, check if they exist in the ESRB Dump,
# and then add the ESRB game ID qualifiers.
items_with_esrb_id_and_no_qualifiers.each do |item|
  progress_bar.increment

  progress_bar.log '----------------'

  next unless esrb_dump.map(&:esrb_id).include?(item['esrbId'].to_s.to_i)

  game = esrb_dump.find { |g| g.esrb_id == item['esrbId'].to_s.to_i }

  progress_bar.log "Evaluating '#{game.title}' with ESRB ID #{game.esrb_id}."

  row = item.to_h

  wikidata_id = row[:item].to_s.sub('http://www.wikidata.org/entity/', '')

  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: ESRB_RATING)
  if existing_claims != {}
    progress_bar.log "This item already has an ESRB Rating."
    next
  end

  # TODO: Add "subject named as" qualifier to ESRB ID.

  # TODO: Add "platform" qualifiers to ESRB ID.

  # To avoid hitting the API rate limit.
  sleep 2
end

progress_bar.finish unless progress_bar.finished?
