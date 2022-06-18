# This script is for dumping all the games on IGDB with the first release date,
# platforms, involved companies, slug, and ID.
#
# It will write the data in a nicely formatted JSON file at `igdb_games.json`.
# There'll be a secondary script written for converting this data into a TSV
# that can be used for Mix'n'match.
#
# Just need these two variables set up:
# TWITCH_CLIENT_ID
# TWITCH_CLIENT_SECRET
#
# See the IGDB API docs for instructions on generating these:
# https://api-docs.igdb.com/#authentication

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'httparty'
end

def twitch_auth
  HTTParty.post(
    "https://id.twitch.tv/oauth2/token",
    body: {
      client_id: ENV['TWITCH_CLIENT_ID'],
      client_secret: ENV['TWITCH_CLIENT_SECRET'],
      grant_type: :client_credentials
    },
  )
end

def igdb_request(body:, access_token:, endpoint: 'games')
  HTTParty.post(
    "https://api.igdb.com/v4/#{endpoint}",
    headers: {
      'Client-ID' => ENV['TWITCH_CLIENT_ID'],
      'Authorization' => "Bearer #{access_token}"
    },
    body: body
  )
end

def igdb_count_body
  <<~APICALYPSE
    where category = 0;
  APICALYPSE
end

def igdb_games_body(offset = 0)
  <<~APICALYPSE
    fields category,first_release_date,name,platforms.name,involved_companies.company.name,slug,status,url,websites.category,websites.url,external_games.category,external_games.url;
    where category = 0;
    sort slug asc;
    limit 500;
    offset #{offset};
  APICALYPSE
end

twitch_auth_hash = twitch_auth.to_h
ACCESS_TOKEN = twitch_auth_hash['access_token']

igdb_count_resp = igdb_request(
  body: igdb_count_body,
  access_token: ACCESS_TOKEN,
  endpoint: 'games/count'
)

TOTAL_GAME_COUNT = igdb_count_resp.parsed_response['count']

puts "There are #{TOTAL_GAME_COUNT} games on IGDB in total..."

igdb_games = []

((TOTAL_GAME_COUNT / 500) + 1).times do |index|
  puts "Iteration #{index + 1}"

  igdb_resp = igdb_request(
    body: igdb_games_body(500 * index),
    access_token: ACCESS_TOKEN
  )

  curr_games = igdb_resp.parsed_response.map do |game|
    game['first_release_date'] ||= nil
    game['platforms'] ||= []
    game['websites'] ||= []
    game['external_games'] ||= []
    unless game['platforms'].count.zero?
      game['platforms'] = game['platforms'].map do |hash|
        # Fix the name for the "PC" platform.
        hash['name'] == "PC (Microsoft Windows)" ? "Microsoft Windows" : hash['name']
      end
    end
    game['involved_companies'] ||= []
    game['involved_companies'] = game['involved_companies'].map { |hash| hash['company']['name'] } unless game['involved_companies'].count.zero?
    game
  end

  igdb_games = igdb_games.concat(curr_games)

  sleep 1
end

puts JSON.pretty_generate(igdb_games)

File.write(File.join(File.dirname(__FILE__), 'igdb_games.json'), JSON.pretty_generate(igdb_games))
