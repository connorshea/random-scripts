# For dumping all the PCGW articles.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
  gem 'httparty'
end

require 'open-uri'
require_relative '../pcgw-export/pcgw_helper.rb'

include PcgwHelper

class PcgwDumper
  class << self

    # @param games [Array<String>] an array of PCGW IDs
    def post_export(games)
      return HTTParty.post(
        'https://www.pcgamingwiki.com/wiki/Special:Export',
        body: {
          catname: '',
          pages: games.join("\r\n"),
          curonly: '1',
          wpDownload: '1',
          wpEditToken: '+\\',
          title: 'Special:Export'
        }
      )
    end

    def dumps_file_path
      File.join(File.dirname(__FILE__), 'dumps')
    end
  end
end

if ENV['CREATE_PCGW_ARTICLES_JSON']
  puts 'Creating pcgw_articles.json, this may take a while...'
  
  articles_with_steam_app_ids = PcgwHelper.get_all_pages_with_property(:steam_app_id)
  
  File.write(File.join(File.dirname(__FILE__), 'pcgw_articles.json'), JSON.pretty_generate(articles_with_steam_app_ids))
  puts 'Successfully created pcgw_articles.json.'
else
  puts 'Continuing with PCGW dump. Set CREATE_PCGW_ARTICLES_JSON environment variable if you need to create pcgw_articles.json first.'
end

articles = JSON.load(File.open(File.join(File.dirname(__FILE__), 'pcgw_articles.json')))

# Yeet anything with really weird characters in the title.
articles = articles.reject do |article|
  ['<', '>', '%'].any? { |i| article['fullurl'].include?(i) }
end

articles = articles.map { |article| article['fullurl'].gsub('https://www.pcgamingwiki.com/wiki/', '') }

# Create dumps in sets of 5000.
articles.each_slice(5000).with_index do |article_slice, i|
  puts "Dump #{i}"
  dump = PcgwDumper.post_export(article_slice)
  File.write(File.join(PcgwDumper.dumps_file_path, "dump#{i}.xml"), dump)
end

