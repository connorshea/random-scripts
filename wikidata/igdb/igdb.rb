require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'json'
require 'sparql/client'
require 'open-uri'
require 'mediawiki_api'
require 'mediawiki_api/wikidata/wikidata_client'
require 'net/https'
require_relative '../wikidata_helper.rb'

include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

# Get video games on Wikidata with a Steam App ID and no IGDB ID.
def query
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel ?steamAppId WHERE
    {
      ?item wdt:P31 wd:Q7889; # instance of video game
            wdt:P1733 ?steamAppId. # on Steam
      FILTER NOT EXISTS { ?item wdt:P5794 ?igdbId . } # with no IGDB ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL

  sparql
end

def igdb_api_request(body:, endpoint: 'games')
  http = Net::HTTP.new('api-v3.igdb.com',443)
  http.use_ssl = true
  request = Net::HTTP::Post.new(URI("https://api-v3.igdb.com/#{endpoint}"), {'user-key' => ENV['IGDB_API_KEY']})
  request.body = body
  body = http.request(request).body

  return body
end

def get_websites
  body = igdb_api_request(endpoint: 'games', body: 'fields name,slug,url,websites;')

  games = JSON.parse(body)

  puts JSON.pretty_generate(games)

  games_with_websites = []

  games.each do |game|
    next if game['websites'].nil?

    games_with_websites << {
      id: game['id'],
      name: game['name'],
      slug: game['slug'],
      websites: game['websites']
    }
  end

  puts games_with_websites.inspect

  website_categories = {
    1 => :official,
    2 => :wikia,
    3 => :wikipedia,
    4 => :facebook,
    5 => :twitter,
    6 => :twitch,
    8 => :instagram,
    9 => :youtube,
    10 => :iphone,
    11 => :ipad,
    12 => :android,
    13 => :steam,
    14 => :reddit,
    15 => :itch,
    16 => :epicgames,
    17 => :gog
  }

  games_with_websites.each do |game|
    game[:websites]&.each do |website_id|
      response = igdb_api_request(endpoint: 'websites', body: "fields category,game,trusted,url; where id = #{website_id};")

      puts "RESPONSE"
      website = JSON.parse(response)
      website = website[0]

      puts website.inspect
      puts "#{game[:slug]}: #{website['url']}" if website["category"] == 13
    end
  end
end

def get_external_ids
  continue = true
  i = 0
  games = []

  while continue == true
    # Get Steam IDs for IGDB.
    body = igdb_api_request(endpoint: 'external_games', body: "fields game,name,category,uid,url; where category = 1; limit 25; offset #{i * 25};")

    igdb_response = JSON.parse(body)

    puts JSON.pretty_generate(igdb_response)

    igdb_response.each do |game|
      next unless game.key?("game")
      games << {
        game_id: game["game"],
        name: game["name"],
        steam_id: game["uid"].to_i
      }
    end

    i += 1

    continue = false if i >= 200
    sleep 1
  end

  File.write("igdb_games.json", JSON.pretty_generate(games))
end

def get_igdb_slugs_from_games_json
  games = JSON.load(File.read("igdb_games.json"))

  games_new = []

  # Get game data in sets of 10.
  games.each_slice(10) do |game_set|
    body = igdb_api_request(endpoint: 'games', body: "fields id,name,slug; where id = (#{game_set.map { |g| g['game_id'] }.join(',')});")
    igdb_response = JSON.parse(body)

    igdb_response.each do |igdb_game|
      game = game_set.find { |game| game['game_id'] == igdb_game['id'].to_i }
      game['slug'] = igdb_game['slug']

      games_new << game
    end

    puts games_new.count
    sleep 1
  end

  File.write("igdb_games_with_slugs.json", JSON.pretty_generate(games_new))
end

# Given the data from the above methods, import the IGDB IDs into Wikidata by
# matching them via Steam IDs.
def import_igdb_ids_into_wikidata
  sparql_client = SPARQL::Client.new(
    "https://query.wikidata.org/sparql",
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 2.6" }
  )

  # Get the response from the Wikidata query.
  sparql = query
  rows = sparql_client.query(sparql)

  steam_app_ids = rows.map { |row| row.to_h[:steamAppId].to_s.to_i }

  igdb_games = JSON.load(File.read("igdb_games_with_slugs.json"))

  matchable_igdb_games = igdb_games.filter { |game| steam_app_ids.include?(game['steam_id']) }

  # Authenticate with Wikidata.
  wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
  wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

  progress_bar = ProgressBar.create(
    total: matchable_igdb_games.count,
    format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
  )

  matchable_igdb_games.each do |igdb_game|
    wikidata_item = rows.find { |row| row.to_h[:steamAppId].to_s.to_i == igdb_game['steam_id'] }

    wikidata_id = wikidata_item.to_h[:item].to_s.sub('http://www.wikidata.org/entity/', '')

    existing_claims = WikidataHelper.get_claims(entity: wikidata_id, property: 'P5794')
    if existing_claims != {}
      progress_bar.log "This item already has an IGDB ID."
      progress_bar.increment
      next
    end

    # Make sure the names match.
    unless wikidata_item[:itemLabel].to_s.downcase == igdb_game['name'].downcase
      progress_bar.log "Names don't match, skipping. (#{wikidata_item[:itemLabel]}, #{igdb_game['name']})"
      progress_bar.increment
      next
    end

    progress_bar.log "Adding #{igdb_game['slug']} to #{wikidata_item[:itemLabel]}"

    begin
      claim = wikidata_client.create_claim(wikidata_id, "value", "P5794", "\"#{igdb_game['slug']}\"")
    rescue MediawikiApi::ApiError => e
      progress_bar.log e
    end

    progress_bar.increment
    sleep 1
  end

  progress_bar.finish unless progress_bar.finished?
end

# get_external_ids()
# get_igdb_slugs_from_games_json()
import_igdb_ids_into_wikidata()
