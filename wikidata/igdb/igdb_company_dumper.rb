# This script is for dumping all the companies on IGDB with the slug and ID.
#
# It will write the data in a nicely formatted JSON file at `igdb_companies.json`.
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

def igdb_request(body:, access_token:, endpoint: 'companies')
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
    where name != null;
  APICALYPSE
end

def igdb_companies_body(offset = 0)
  <<~APICALYPSE
    fields name,slug,description,change_date,country,developed.name,published.name;
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
  endpoint: 'companies/count'
)

TOTAL_COMPANY_COUNT = igdb_count_resp.parsed_response['count']

puts "There are #{TOTAL_COMPANY_COUNT} companies on IGDB in total..."

igdb_companies = []

((TOTAL_COMPANY_COUNT / 500) + 1).times do |index|
  puts "Iteration #{index + 1}"

  igdb_resp = igdb_request(
    body: igdb_companies_body(500 * index),
    access_token: ACCESS_TOKEN
  )

  curr_companies = igdb_resp.parsed_response.map do |company|
    company['change_date'] ||= nil
    company['country'] ||= nil
    company['description'] ||= nil
    company['developed'] ||= []
    company['developed'] = company['developed'].first(3).map { |developed| developed['name'] }
    company['published'] ||= []
    company['published'] = company['published'].first(3).map { |published| published['name'] }
    company
  end

  igdb_companies = igdb_companies.concat(curr_companies)

  sleep 1
end

puts JSON.pretty_generate(igdb_companies)

File.write(File.join(File.dirname(__FILE__), 'igdb_companies.json'), JSON.pretty_generate(igdb_companies))
