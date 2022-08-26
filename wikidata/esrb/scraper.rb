# frozen_string_literal: true
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'

  gem 'httparty', '~> 0.20.0'
end

require 'json'
require 'httparty'

class EsrbScraper
  ESRB_URL = 'https://www.esrb.org/wp-admin/admin-ajax.php'.freeze

  def self.search_esrb(page:)
    api(page: page)['games']
  end

  def self.esrb_game_count
    api(page: 1)['total']
  end

  private

  def self.api(page:)
    options = {
      body: {
        "action": "search_rating",
        "args[searchKeyword]": "",
        "args[searchType]": "LatestRatings",
        "args[timeFrame]": "All",
        "args[pg]": page.to_s,
        "args[platform][]": "All+Platforms",
        "args[descriptor][]": "All+Content",
        "args[ielement][]": "all",
      }
    }

    response = HTTParty.post(ESRB_URL, options)
    results = JSON.parse(response.body)
    results
  end
end

i = 1
end_of_results = false
games = []

total_pages = EsrbScraper.esrb_game_count.fdiv(10).floor

while end_of_results == false
  puts "Page #{i}/#{total_pages}, games array size: #{games.length}"

  results = EsrbScraper.search_esrb(page: i)

  if results.length == 0
    end_of_results = true
    next
  end

  games = games.concat(results)
  i += 1
  sleep 0.5
end

File.write('wikidata/esrb/esrb_dump.json', JSON.pretty_generate(games))
