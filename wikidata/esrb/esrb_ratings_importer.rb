# frozen_string_literal: true

# Script to add ESRB Ratings to items.
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

items_with_esrb_id_and_no_rating = client.query(items_with_esrb_id_and_no_rating_query)

wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

progress_bar = ProgressBar.create(
  total: items_with_esrb_id_and_no_rating.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

# Go through each item in the SPARQL response, check if they exist in the ESRB Dump,
# and then add the ESRB Rating along with the qualifiers for the content descriptors,
# and a reference.
items_with_esrb_id_and_no_rating.each do |item|
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
    # The gem doesn't let us set qualifiers with novalue, so we have to use the action method directly.
    wikidata_client.action(:wbsetqualifier, token_type: "csrf", claim: claim_id, snaktype: 'novalue', property: CONTENT_DESCRIPTOR_PID)
  else
    progress_bar.log 'Adding content descriptor qualifiers to ESRB Rating statement...'
    qualifier_snak[CONTENT_DESCRIPTOR_PID].each do |descriptor|
      wikidata_client.set_qualifier(claim_id, 'value', CONTENT_DESCRIPTOR_PID, descriptor.to_json)
    end
  end

  if qualifier_snak[ESRB_INTERACTIVE_ELEMENTS_PID].empty?
    progress_bar.log("No interactive elements declared for #{game.title}.")
    # The gem doesn't let us set qualifiers with novalue, so we have to use the action method directly.
    wikidata_client.action(:wbsetqualifier, token_type: "csrf", claim: claim_id, snaktype: 'novalue', property: ESRB_INTERACTIVE_ELEMENTS_PID)
  else
    progress_bar.log 'Adding interactive elements qualifiers to ESRB Rating statement...'
    qualifier_snak[ESRB_INTERACTIVE_ELEMENTS_PID].each do |interactive_elem|
      wikidata_client.set_qualifier(claim_id, 'value', ESRB_INTERACTIVE_ELEMENTS_PID, interactive_elem.to_json)
    end
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
  sleep 1
end

progress_bar.finish unless progress_bar.finished?
