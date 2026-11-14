# This script is for dumping all the games on IGDB with the first release date,
# platforms, involved companies, slug, and ID.
#
# It will write the data in a nicely formatted JSON file at `igdb_games.json`.
# `igdb_mixnmatch_generator.rb` converts this data into a TSV that can be used
# for Mix'n'match.
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

require 'json'

# IGDB returns at most 500 results per query, and a multiquery request can
# contain up to 10 queries. Responses are also capped at 10MB, so start with
# 4 queries (2,000 games) per request and split a batch in half if it's still
# too large.
PAGE_SIZE = 500
QUERIES_PER_REQUEST = 4
# IGDB allows 4 requests per second.
REQUEST_INTERVAL = 0.25
MAX_RETRIES = 5

# `category` was deprecated in favor of `game_type` (0 = main game), and
# `websites.category` / `external_games.category` were replaced by
# `websites.type` / `external_games.external_game_source`. The IDs are the
# same as the old enum values.
GAME_FIELDS = %w[
  game_type
  first_release_date
  name
  platforms.name
  involved_companies.company.name
  slug
  game_status
  url
  websites.type
  websites.url
  external_games.external_game_source
  external_games.url
  external_games.uid
].join(',').freeze

GAME_FILTER = 'where game_type = 0;'.freeze

def twitch_auth
  resp = HTTParty.post(
    'https://id.twitch.tv/oauth2/token',
    body: {
      client_id: ENV.fetch('TWITCH_CLIENT_ID'),
      client_secret: ENV.fetch('TWITCH_CLIENT_SECRET'),
      grant_type: :client_credentials
    }
  )
  raise "Twitch auth failed (#{resp.code}): #{resp.body}" unless resp.success?

  resp.parsed_response.fetch('access_token')
end

# IGDB rejects responses over 10MB with a 413.
class PayloadTooLarge < StandardError; end

# POST to an IGDB endpoint, retrying on rate limits and server errors.
def igdb_request(body:, access_token:, endpoint:)
  attempts = 0
  loop do
    attempts += 1
    resp = HTTParty.post(
      "https://api.igdb.com/v4/#{endpoint}",
      headers: {
        'Client-ID' => ENV.fetch('TWITCH_CLIENT_ID'),
        'Authorization' => "Bearer #{access_token}"
      },
      body: body
    )
    return resp.parsed_response if resp.success?
    raise PayloadTooLarge if resp.code == 413

    retryable = resp.code == 429 || resp.code >= 500
    raise "IGDB request failed (#{resp.code}): #{resp.body}" unless retryable && attempts < MAX_RETRIES

    backoff = 2**attempts
    puts "Got #{resp.code}, retrying in #{backoff}s (attempt #{attempts}/#{MAX_RETRIES})..."
    sleep backoff
  end
end

def page_query(offset)
  <<~APICALYPSE
    query games "#{offset}" {
      fields #{GAME_FIELDS};
      #{GAME_FILTER}
      sort id asc;
      limit #{PAGE_SIZE};
      offset #{offset};
    };
  APICALYPSE
end

# Flatten nested objects and add defaults for missing keys.
def normalize_game(game)
  game['first_release_date'] ||= nil
  game['websites'] ||= []
  game['external_games'] ||= []
  game['platforms'] = (game['platforms'] || []).map do |platform|
    # Fix the name for the "PC" platform.
    platform['name'] == 'PC (Microsoft Windows)' ? 'Microsoft Windows' : platform['name']
  end
  game['involved_companies'] = (game['involved_companies'] || []).filter_map { |ic| ic.dig('company', 'name') }

  # Keep the old `category` keys so the other scripts in this directory that
  # read igdb_games.json keep working.
  game['category'] = game['game_type']
  game['status'] = game['game_status']
  game['websites'].each { |w| w['category'] = w['type'] }
  game['external_games'].each { |e| e['category'] = e['external_game_source'] }

  game
end

# Fetch a batch of pages in one multiquery request, splitting it in half and
# retrying if the response exceeds IGDB's size limit.
def fetch_batch(batch, access_token)
  results = igdb_request(
    body: batch.map { |offset| page_query(offset) }.join("\n"),
    access_token: access_token,
    endpoint: 'multiquery'
  )
  # Results come back in query order, but sort by offset to be safe.
  results.sort_by { |r| r['name'].to_i }
rescue PayloadTooLarge
  raise 'A single page of games exceeds the 10MB response limit; lower PAGE_SIZE.' if batch.size == 1

  puts "  Response too large, splitting #{batch.size} pages into two requests..."
  sleep REQUEST_INTERVAL
  first, second = batch.each_slice((batch.size / 2.0).ceil).to_a
  first_results = fetch_batch(first, access_token)
  sleep REQUEST_INTERVAL
  first_results + fetch_batch(second, access_token)
end

access_token = twitch_auth

total_count = igdb_request(
  body: GAME_FILTER,
  access_token: access_token,
  endpoint: 'games/count'
).fetch('count')

puts "There are #{total_count} games on IGDB in total..."

offsets = (0...total_count).step(PAGE_SIZE).to_a
batches = offsets.each_slice(QUERIES_PER_REQUEST).to_a
igdb_games = []

batches.each_with_index do |batch, index|
  started_at = Time.now
  puts "Request #{index + 1}/#{batches.count} (offsets #{batch.first}-#{batch.last + PAGE_SIZE - 1})"

  fetch_batch(batch, access_token).each do |result|
    igdb_games.concat(result['result'].map { |game| normalize_game(game) })
  end

  elapsed = Time.now - started_at
  sleep(REQUEST_INTERVAL - elapsed) if elapsed < REQUEST_INTERVAL
end

# Guard against duplicates in case the data shifted between requests.
igdb_games.uniq! { |game| game['id'] }

puts "Fetched #{igdb_games.count} games (expected #{total_count})."

File.write(File.join(__dir__, 'igdb_games.json'), JSON.pretty_generate(igdb_games))
