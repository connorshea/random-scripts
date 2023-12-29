# Given a CSV from Wikidata and a CSV from OpenRefine, this script will
# add the GiantBomb ID from Wikidata to the OpenRefine CSV.
#
# We can then import that back into OpenRefine and generate a
# QuickStatements batch that adds GiantBomb IDs to all of
# these items.
#
# We check the GiantBomb IDs by making an HTTP request to GiantBomb
# to ensure their validity before we go to import them through OpenRefine.
#
# Use the following query to get the query2.csv file for use with this script: 
#
# SELECT ?item ?itemLabel (SAMPLE(?gbId) as ?gbId) WHERE {
#   ?item wdt:P31 wd:Q7889; # instance of video game
#   wdt:P5247 ?gbId. # items with a GB ID.
# SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE],en". }
# }
# GROUP BY ?item ?itemLabel

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'httparty'
  gem 'nokogiri'
end

require 'json'
require 'csv'
require 'nokogiri'

# For comparing using Levenshtein Distance.
# https://stackoverflow.com/questions/16323571/measure-the-distance-between-two-strings-with-ruby
require "rubygems/text"

def games_have_same_name?(name1, name2)
  name1 = name1.downcase
  name2 = name2.downcase
  return true if name1 == name2

  name1 = name1.gsub('&', 'and')
  name2 = name2.gsub('&', 'and')

  levenshtein = Class.new.extend(Gem::Text).method(:levenshtein_distance)

  distance = levenshtein.call(name1, name2)
  return true if distance <= 2

  return true if name1 == name2

  return false
end

# CSV from OpenRefine
openrefine_csv = CSV.parse(File.read('./igdb-games-transformed-retry.csv'), headers: true)
# Wikidata Query Service CSV
wdqs_csv = CSV.parse(File.read('./query2.csv'), headers: true)

giantbomb_ids_from_wikidata = wdqs_csv.map do |row|
  {
    wikidata_id: row['item'].split('/').last,
    giantbomb_id: row['gbId']
  }
end.sort_by { |row| row[:wikidata_id] }

# Go through the OpenRefine CSV and add a new column with the giantbomb ID from Wikidata where possible
openrefine_csv.each do |row|
  giantbomb_id = giantbomb_ids_from_wikidata.bsearch { |item| row['wikidata_id'] <=> item[:wikidata_id] }&.dig(:giantbomb_id)
  row['giantbomb_id_from_wikidata'] = giantbomb_id
end

# Remove rows where the giantbomb ID from Wikidata is present or the giantbomb ID from IGDB is missing
openrefine_csv.delete_if do |row|
  !row['giantbomb_id_from_wikidata'].nil? || row['giantbomb_id'].nil?
end

# Make an HTTP request to GiantBomb for each row and delete the row if the
# request 404s or the page title is different from the name from the CSV.
openrefine_csv.delete_if do |row|
  sleep 0.5 # Avoid rate limiting/banning
  url = "https://www.giantbomb.com/wd/#{row['giantbomb_id']}/"
  puts url
  response = HTTParty.get(url)
  if response.code == 404
    puts "404"
    true
  else
    doc = Nokogiri::HTML(response.body)
    title = doc.css('a.wiki-title').text
    if !games_have_same_name?(title, row['igdb_name'])
      puts "Title mismatch: #{title} vs #{row['igdb_name']}"
      true
    else
      false
    end
  end
end

# Write the new CSV
CSV.open('./igdb-games-transformed-retry-with-giantbomb-from-wikidata.csv', 'wb') do |csv|
  csv << openrefine_csv.headers
  openrefine_csv.each do |row|
    csv << row
  end
end
