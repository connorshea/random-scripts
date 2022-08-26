# frozen_string_literal: true

# Script to add ESRB Ratings and ESRB ID Qualifiers to items.
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

# Wikidata QIDs for Interactive Elements values.
INTERACTIVE_ELEMENTS = {
  'Online Interactions Not Rated by the ESRB': 68183722,
  'Music Downloads and/or Streams Not Rated by the ESRB': 96220171,
  'Online Music Not Rated by the ESRB': 96220186,
  'Users Interact': 69430207,
  'In-Game Purchases': 69991173,
  'In-Game Purchases (Includes Random Items)': 90412335,
  'Shares Location': 69430054,
  'Unrestricted Internet': 69430020,
  'Shares Info': 97363751,
  'Game Experience May Change During Online Play': 97302889,
  'Digital Purchases': 102110695,
  'In-App Purchases': 106097196
}.freeze

# Wikidata QIDs for ESRB Content Descriptors
CONTENT_DESCRIPTORS = {
  'Cartoon Violence': 60316462,
  'Animated Violence': 69577345,
  'Realistic Violence': 69583053,
  'Crude Humor': 60300344,
  'Mature Humor': 60317589,
  'Animated Blood': 60316460,
  'Fantasy Violence': 60317581,
  'Violence': 60324429,
  'Mild Violence': 60324381,
  'Intense Violence': 60317584,
  'Blood and Gore': 60316461,
  'Realistic Blood and Gore': 69582662,
  'Mild Language': 68205918,
  'Strong Language': 60300342,
  'Use of Alcohol': 60324427,
  'Use of Drugs': 60324426,
  'Suggestive Themes': 60324424,
  'Strong Lyrics': 60324421,
  'Sexual Content': 69578048,
  'Strong Sexual Content': 60324423,
  'Nudity': 60324383,
  'Partial Nudity': 60300245,
  'Sexual Themes': 60324385,
  'Simulated Gambling': 60324387,
  'Gambling': 97543276,
  'Drug Reference': 60317579,
  'Alcohol and Tobacco Reference': 99904297,
  'Edutainment': 60300293,
  'Blood': 60316463,
  'Mild Blood': 77315029,
  'Language': 60317586,
  'Mild Suggestive Themes': 72415417,
  'Mild Sexual Themes': 97585290,
  'Mild Fantasy Violence': 70002023,
  'Alcohol Reference': 60316458,
  'Comic Mischief': 60316464,
  'Lyrics': 60317587,
  'Use of Tobacco': 60324428,
  'Violent References': 69573910,
  'Use of Alcohol and Tobacco': 96337561,
  'Mild Lyrics': 96310546,
  'Mild Cartoon Violence': 69993985,
  'Use of Drugs and Alcohol': 86235040,
  'Tobacco Reference': 60324425,
  'Drug and Alcohol Reference': 110343784,
  'Sexual Violence': 60324386,
  'Animated Blood and Gore': 69577075,
  'Mature Sexual Themes': 69821734,
  'Mild Animated Violence': 97656786,
  'Informational': 60724353,
  'Some Adult Assistance May Be Needed': 60324422,
  'Gaming': 103531650,
  'Realistic Blood': 98556739,
  'Mild Realistic Violence': 97656787
}.freeze

# Wikidata QIDs for Ratings values
ESRB_RATINGS = {
  'E': 14864328,
  'E10+': 14864329,
  'T': 14864330,
  'M': 14864331,
  'EC': 14864327,
  'AO': 14864332
}.freeze

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

# Get all the Wikidata items with ESRB game IDs and no ESRB Rating.
#
# Some of these have "unknown value" set, and I'm not sure how to get rid of them.
# It'll have a value like this for the ESRB game ID if it's "unknown value":
# `<http://www.wikidata.org/.well-known/genid/f8296fb7b964d7c179cb7499ba719b55>`
def items_with_esrb_id_and_no_rating_query
  <<-SPARQL
    SELECT DISTINCT ?item ?itemLabel ?esrbId WHERE {
      ?item wdt:P31 wd:Q7889. # Items that are an instance of video game
      ?item wdt:P8303 ?esrbId. # with an ESRB ID
      FILTER NOT EXISTS { ?item wdt:P852 ?esrbRating . } # with no ESRB Rating

      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE]". }
    }
  SPARQL
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
      "snaktype" => "value",
      "property" => CONTENT_DESCRIPTOR_PID,
      "datatype" => "wikibase-item",
      "datavalue" => {
        "value" => {
          "entity-type" => "item",
          "numeric-id" => CONTENT_DESCRIPTORS[descriptor.to_sym],
          "id" => "Q#{CONTENT_DESCRIPTORS[descriptor.to_sym]}"
        },
        "type" => "wikibase-entityid"
      }
    }
  end

  game.interactive_elements.each do |interactive_elem|
    unless INTERACTIVE_ELEMENTS.keys.map(&:to_s).include?(interactive_elem)
      progress_bar.log "'#{interactive_elem}' could not be found in the list of interactive elements QIDs."
      next
    end

    snak[ESRB_INTERACTIVE_ELEMENTS_PID] << {
      "snaktype" => "value",
      "property" => ESRB_INTERACTIVE_ELEMENTS_PID,
      "datatype" => "wikibase-item",
      "datavalue" => {
        "value" => {
          "entity-type" => "item",
          "numeric-id" => INTERACTIVE_ELEMENTS[interactive_elem.to_sym],
          "id" => "Q#{INTERACTIVE_ELEMENTS[interactive_elem.to_sym]}"
        },
        "type" => "wikibase-entityid"
      }
    }
  end

  return snak
end

client = SPARQL::Client.new(
  ENDPOINT,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+rubyscripts@gmail.com) Ruby 3.1" }
)

items_with_esrb_id_and_no_rating = client.query(items_with_esrb_id_and_no_rating_query)
items_with_esrb_id_and_no_qualifiers = client.query(items_with_esrb_id_and_no_qualifiers_query)

wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

progress_bar = ProgressBar.create(
  total: esrb_dump.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

# TODO: get the intersection of esrb_dump and the items from SPARQL so the
#       progress bar estimation is more accurate and we waste less time?

# Go through each item in the ESRB dump, check if they have a rating set in
# Wikidata, and if not, add it along with the qualifiers for the content
# descriptors, and a reference.
esrb_dump.each do |game|
  progress_bar.increment
  progress_bar.log '--------------'

  progress_bar.log "Evaluating '#{game.title}' with ESRB ID #{game.esrb_id}."

  next unless items_with_esrb_id_and_no_rating.map { |g| g['esrbId'].to_s.to_i }.include?(game.esrb_id)

  row = items_with_esrb_id_and_no_rating.find { |g| g['esrbId'].to_s.to_i == game.esrb_id }.to_h

  wikidata_id = row[:item].to_s.sub('http://www.wikidata.org/entity/', '')

  existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: ESRB_RATING)
  if existing_claims != {}
    progress_bar.log "This item already has an ESRB Rating."
    next
  end

  progress_bar.log "Adding ESRB Rating #{game.rating} to #{row[:itemLabel]}"
  rating_qid = ESRB_RATINGS[game.rating.to_sym]

  if rating_qid.nil?
    progress_bar.log "Rating '#{game.rating}' on ESRB ID #{game.esrb_id} is invalid."
    next
  end

  begin
    progress_bar.log rating_qid.inspect if ENV['DEBUG']
    claim = wikidata_client.create_claim(
      wikidata_id,
      "value",
      ESRB_RATING,
      {
        "entity-type": "item",
        "numeric-id": rating_qid,
        "id": "Q#{rating_qid}"
      }.to_json
    )
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
    next
  end

  # Get the claim ID returned from the create_claim method.
  claim_id = claim.data.dig('claim', 'id')

  # Add qualifiers to the newly-created ESRB rating claim.
  qualifier_snak = generate_rating_qualifier_snak(game, progress_bar)

  if qualifier_snak[CONTENT_DESCRIPTOR_PID].empty?
    progress_bar.log("No content descriptors declared for #{game.title}.")
  else
    progress_bar.log 'Adding content descriptor qualifiers to ESRB Rating statement...'
    wikidata_client.set_qualifier(claim_id, 'value', CONTENT_DESCRIPTOR_PID, qualifier_snak[CONTENT_DESCRIPTOR_PID])
  end

  if qualifier_snak[ESRB_INTERACTIVE_ELEMENTS_PID].empty?
    progress_bar.log("No interactive elements declared for #{game.title}.")
  else
    progress_bar.log 'Adding interactive elements qualifiers to ESRB Rating statement...'
    wikidata_client.set_qualifier(claim_id, 'value', ESRB_INTERACTIVE_ELEMENTS_PID, qualifier_snak[ESRB_INTERACTIVE_ELEMENTS_PID])
  end

  # Add references to statement
  reference_snak = {
    REFERENCE_PROPERTIES[:stated_in] => [
      {
        "snaktype" => "value",
        "property" => REFERENCE_PROPERTIES[:stated_in],
        "datatype" => "wikibase-item",
        "datavalue" => {
          "value" => {
            "entity-type" => "item",
            "numeric-id" => ESRB_RATINGS_DATABASE,
            "id" => "Q#{ESRB_RATINGS_DATABASE}"
          },
          "type" => "wikibase-entityid"
        }
      }
    ],
    ESRB_GAME_ID => [
      {
        "snaktype" => "value",
        "property" => ESRB_GAME_ID,
        "datavalue": {
          "value": game.esrb_id.to_s,
          "type": "string"
        },
        "datatype": "external-id"
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
    wikidata_client.set_reference(claim_id, reference_snak.to_json)
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
  end

  # To avoid hitting the API rate limit.
  sleep 2
end

progress_bar.finish unless progress_bar.finished?
