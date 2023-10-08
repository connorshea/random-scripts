# frozen_string_literal: true

##
# USAGE:
#
# This script pulls every game on Wikidata with at least one defined publication
# date and an English description of just 'video game', and then updates the
# item with the year of its publication, e.g. '2004 video game'.
#
# ENVIRONMENT VARIABLES:
#
# WIKIDATA_USERNAME: username for Wikidata account
# WIKIDATA_PASSWORD: password for Wikidata account
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'nokogiri'
  gem 'ruby-progressbar', '~> 1.10'
  gem 'debug'
end

require 'sparql/client'
require 'json'
require 'debug'

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

endpoint = "https://query.wikidata.org/sparql"

def query
  <<-SPARQL
    SELECT ?item ?itemLabel (GROUP_CONCAT(?publicationDate) AS ?pubDates) WHERE
    {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P577 ?publicationDate. # with a publication date
      ?item schema:description ?description . FILTER(LANG(?description) = "en")
      FILTER regex(?description, '^video game$') # English description is just 'video game'
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    } 
    GROUP BY ?item ?itemLabel
  SPARQL
end

# Authenticate with Wikidata.
def get_wikidata_client
  client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
  client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]
  client
end

sparql_client = SPARQL::Client.new(
  endpoint,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
)

rows = sparql_client.query(query)

wikidata_client = get_wikidata_client

progress_bar = ProgressBar.create(
  total: rows.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

rows.each do |row|
  progress_bar.increment
  hash = row.to_h

  num_publication_dates = hash[:pubDates].to_s.split(' ').length
  if num_publication_dates > 1
    progress_bar.log "More than one publication date found for #{hash[:itemLabel].to_s}, skipping..."
    next
  end

  new_description = "#{Date.parse(hash[:pubDates].to_s).year} video game"

  item_id = hash[:item].to_s.sub('http://www.wikidata.org/entity/', '')

  progress_bar.log "Adding new description to #{item_id}: #{new_description}"

  begin
    wikidata_client.action(:wbsetdescription, id: item_id, language: 'en', value: new_description)
  rescue MediawikiApi::ApiError => e
    progress_bar.log e
  end

  sleep 0.5
end

progress_bar.finish unless progress_bar.finished?

puts 'Complete!'
