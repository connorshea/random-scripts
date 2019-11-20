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
    all_pages.concat(get_all_humble_store_pages(limit: limit, offset: pages['query-continue-offset'].to_i))
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

# humble_pages = get_all_humble_store_pages(limit: 300)

# Was having trouble getting the data programmatically so we're doing this from a local JSON file :)
humble_store_json_file = File.join(File.dirname(__FILE__), 'humble-store-ids.json')
humble_pages = JSON.load(File.read(humble_store_json_file))

humble_pages = humble_pages['query']['results']
humble_pages = humble_pages.map { |page| page[1]["fullurl"].sub('https://www.pcgamingwiki.com/wiki/', '') }

# puts humble_pages.inspect

puts "#{humble_pages.count} pages to purge"
humble_pages.each_with_index do |page, index|
  puts "Purging #{page}"
  response = client.action :purge, titles: URI.unescape(page), formatversion: 2
  puts response.data.first['purged']
  puts response.warnings.inspect
  sleep 2
  begin
    URI.open("https://www.pcgamingwiki.com/wiki/#{page}")
  rescue OpenURI::HTTPError => e
    puts e
  end
  puts index
end

#   batch_count.times do |batch_num|
#   next if batch_num < 6
#   puts "Purging 40 PCGW articles."
#   current_batch = humble_pages[(40 * batch_num)..(40 * (batch_num + 1))]
#   titles = current_batch.map { |x| URI.unescape(x) }.join('|')
#   puts titles
#   response = client.action :purge, titles: titles, formatversion: 2
#   puts response.inspect
#   puts response.warnings.inspect
#   puts "Purge done, sleeping..."
#   sleep 30
# end

