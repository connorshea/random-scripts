require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
end

require 'json'
require 'sparql/client'
require 'open-uri'
require 'mediawiki_api'
require 'mediawiki_api/wikidata/wikidata_client'
require 'net/https'

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

  matchable_igdb_games.each do |igdb_game|
    puts igdb_game
  end
end

# get_external_ids()
# get_igdb_slugs_from_games_json()
import_igdb_ids_into_wikidata()
