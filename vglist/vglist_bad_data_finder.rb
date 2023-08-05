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
require 'open-uri'
require 'net/http'

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

# Query to find all items that are video games, video game mods, video
# game compilations, or video game expansion packs.
def query
  <<-SPARQL
    SELECT DISTINCT ?item WHERE {
      {
        ?item p:P31 ?statement0.
        ?statement0 (ps:P31/(wdt:P279*)) wd:Q7889.
      }
      UNION
      {
        ?item p:P31 ?statement1.
        ?statement1 (ps:P31) wd:Q16070115.
      }
      UNION
      {
        ?item p:P31 ?statement2.
        ?statement2 (ps:P31/(wdt:P279*)) wd:Q865493.
      }
      UNION
      {
        ?item p:P31 ?statement3.
        ?statement3 (ps:P31) wd:Q209163.
      }
    }
  SPARQL
end

# @param id [String] e.g. "Q123"
# @return [Boolean]
def item_is_deleted?(id)
  url = "https://www.wikidata.org/wiki/#{id}"

  uri = URI(url)

  response = Net::HTTP.get_response(uri)
  response_code = response.code.to_i

  # It was deleted if it 404s.
  response_code == 404
end

# @param id [String] e.g. "Q123"
# @return [Boolean]
def item_is_redirected?(id)
  url = "https://www.wikidata.org/wiki/#{id}?redirect=no"

  uri = URI(url)

  response = Net::HTTP.get_response(uri)
  response.body.include?('Redirect to:') && response.body.include?('mw-redirect')
end

# # This item was deleted.
# puts item_is_deleted?('Q116773099')
# # This item is a redirect.
# puts item_is_redirected?('Q116169761')

sparql_endpoint = "https://query.wikidata.org/sparql"

client = SPARQL::Client.new(
  sparql_endpoint,
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 3.1" }
)

rows = client.query(query)
wikidata_ids = rows.map { |g| g['item'].to_s.gsub('http://www.wikidata.org/entity/Q', '').to_i }

vglist_games = JSON.parse(File.read('vglist/vglist_games.json'))
vglist_wikidata_ids = vglist_games.map { |g| g['wikidata_id'] }

# Get the wikidata IDs in vglist_games which DO NOT have a record in wikidata_video_games

puts "#{vglist_wikidata_ids.difference(wikidata_ids).count} games in vglist that aren't in Wikidata."

vglist_wikidata_ids.difference(wikidata_ids).each do |wikidata_id|
  puts
  puts "https://www.wikidata.org/wiki/Q#{wikidata_id}"
  puts "https://vglist.co/games/#{vglist_games.find { |g| g['wikidata_id'] == wikidata_id }['id']}"
  if item_is_deleted?("Q#{wikidata_id}")
    puts "Item was deleted."
  end
  if item_is_redirected?("Q#{wikidata_id}")
    puts "Item was redirected."
  end
  sleep 1
end
