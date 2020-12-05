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

if ENV['CREATE_XML_DUMPS']
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
else
  puts 'Continuing with reading PCGW XML dumps. Set CREATE_XML_DUMPS environment variable if you need to create the dump#{n}.xml files first.'
end

require 'rexml/document'
include REXML

pcgw_metadata = []

# Iterate through each dump in the dumps directory and parse through it.
Dir["#{File.dirname(__FILE__)}/dumps/*.xml"].each do |xml_file_path|
  xml_file = File.open(xml_file_path)

  xml_doc = REXML::Document.new(xml_file)

  # Subtract 1 because there's a siteinfo element, everything else is a page.
  page_count = xml_doc.root.elements.size - 1

  progress_bar = ProgressBar.create(
    total: page_count,
    format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
  )

  xml_doc.root.each_element('page') do |xml_page|
    title = xml_page.get_text('title').to_s
    progress_bar.log(title)
    metadata = {
      title: title,
      pcgw_id: title.gsub(' ', '_')
    }
    article_text = xml_page.get_elements('revision').first.get_text('text').to_s

    metadata[:hltb_id] = article_text.match(/\|hltb[ ]+= ?(?<id>\d+)/)&.[](:id)
    metadata[:igdb_id] = article_text.match(/\|igdb[ ]+= ?(?<id>[\w\-_]+)/)&.[](:id)
    metadata[:mobygames_id] = article_text.match(/\|mobygames[ ]+= ?(?<id>[\w\-_]+)/)&.[](:id)
    metadata[:steam_id] = article_text.match(/\|steam appid[ ]+= ?(?<id>\d+)/)&.[](:id)
    pcgw_metadata << metadata
    progress_bar.increment
  end

  progress_bar.finish
end

File.write(File.join(File.dirname(__FILE__), 'pcgw_metadata.json'), JSON.pretty_generate(pcgw_metadata))

puts "#{pcgw_metadata.length} PCGamingWiki articles parsed."
