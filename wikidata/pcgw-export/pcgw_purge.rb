# frozen_string_literal: true
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'

  gem 'mediawiki_api', require: true
  gem 'addressable'
end

require 'addressable/template'
require 'open-uri'
require 'json'

def get_all_humble_store_pages(limit: 25, offset: 0)
  all_pages = []
  pages = get_humble_store_pages(limit: limit, offset: offset)
  pages.dig('query', 'results').each do |key, result|
    result["name"] = key
    all_pages << result
  end
  if pages.key?('query-continue-offset')
    all_pages.concat(get_all_humble_store_pages(offset: pages['query-continue-offset'].to_i))
  end
  return all_pages
end

def get_humble_store_pages(limit: 25, offset: 0)
  query_options = %i[
    format
    action
    query
  ]

  query_options_string = query_options.join(',')

  # limit 500, offset 100
  # &parameters=limit%3D500%7Coffset%3D100
  # unencoded: limit=500|offset=100

  template = Addressable::Template.new("https://www.pcgamingwiki.com/w/api.php{?#{query_options_string}}")
  template = template.expand(
    'action': 'ask',
    'format': 'json',
    'query': "[[Available from::Humble Store]]|limit=#{limit}|offset=#{offset}"
  )

  puts template if ENV['DEBUG']
  response = JSON.load(open(template))
  puts JSON.pretty_generate(response) if ENV['DEBUG']
  response
end

client = MediawikiApi::Client.new "https://www.pcgamingwiki.com/w/api.php"

client.log_in ENV["PCGW_USERNAME"], ENV["PCGW_PASSWORD"]

humble_pages = get_all_humble_store_pages(limit: 300)

puts humble_pages.inspect

batch_count = humble_pages.count % 40
batch_count.times do |batch_num|
  puts "Purging 40 PCGW articles."
  current_batch = pcgw_ids[(40 * batch_num)..(40 * (batch_num + 1))]
  puts current_batch.join('|')
  client.action :purge, titles: current_batch.join('|')
  puts "Purge done, sleeping..."
  sleep 10
end

