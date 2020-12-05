# For dumping a PCGW Page.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'open-uri'
require_relative '../pcgw-export/pcgw_helper.rb'

include PcgwHelper

class PcgwDumper
  def initialize(page_name)
    @page_name = page_name
    @url = "https://www.pcgamingwiki.com/wiki/#{page_name}"
  end

  def page_contents
    URI.open(@url).read
  end

  def dumped_file_path
    File.join(
      File.dirname(__FILE__),
      'dumps',
      "#{@page_name.downcase.gsub('-', '_').gsub(/[;:!*$#()+.]/, '').gsub('__', '_')}.html"
    )
  end

  attr_reader :page_name
  attr_reader :url
end


# articles_with_steam_app_ids = PcgwHelper.get_all_pages_with_property(:steam_app_id)

# File.write(File.join(File.dirname(__FILE__), 'pcgw_articles.json'), JSON.pretty_generate(articles_with_steam_app_ids))

# page = PcgwDumper.new('Half-Life_2')
# File.write(
#   page.dumped_file_path,
#   page.page_contents
# )


articles = JSON.load(File.open(File.join(File.dirname(__FILE__), 'pcgw_articles.json')))

articles = articles.reject do |article|
  ['<', '>', '%'].any? { |i| article['fullurl'].include?(i) }
end

progress_bar = ProgressBar.create(
  total: articles.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

articles.each do |article|
  progress_bar.increment
  page = PcgwDumper.new(article['fullurl'].gsub('https://www.pcgamingwiki.com/wiki/', ''))
  File.write(
    page.dumped_file_path,
    page.page_contents
  )
end

progress_bar.finish
