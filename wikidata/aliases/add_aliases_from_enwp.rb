# The intent of this script is to check for aliases present in the first
# sentence of an English Wikipedia article, where the alias isn't present
# either as the name of the item itself or in the aliases on Wikidata.
#
# This is specifically for video game items. It (probably) won't make the edits
# itself, just print them into a list for a manual reviewer to go through.
#
# Examples:
# https://www.wikidata.org/wiki/Q18786449 and https://en.wikipedia.org/wiki/Karmaflow
# https://www.wikidata.org/wiki/Q6382691 and https://en.wikipedia.org/wiki/Keef_the_Thief
# https://www.wikidata.org/wiki/Q1760261 and https://en.wikipedia.org/wiki/Landstalker

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'sparql-client'
  gem 'nokogiri'
  gem 'ruby-progressbar', '~> 1.10'
  gem 'wikidatum', '~> 0.3.3'
end

require 'wikidatum'
require 'sparql/client'
require 'json'
require 'net/http'
require 'nokogiri'
require 'erb'

# A SPARQL query for getting all video game items that have an English Wikipedia article.
def query
  <<~SPARQL
    SELECT ?item ?itemLabel ?articleName WHERE {
      ?item wdt:P31 wd:Q7889; # instance of video game
        ^schema:about ?article.
      ?article schema:isPartOf <https://en.wikipedia.org/>; # with an enwp article
        schema:name ?articleName.
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
  SPARQL
end

def pull_potential_alias_from_enwp(title)
  # Select the italicized, bold text from the first paragraph element directly
  # descendant from the article's contents.
  selector = '.mw-parser-output > p:first-of-type i b'

  uri = URI("https://en.wikipedia.org/wiki/#{title}")
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = 'Ruby Wikidata importer'
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end

  # Grab the potential alias from the HTML contents of the page.
  Nokogiri::HTML(response.body).at_css(selector)&.text 
end

sparql_client = SPARQL::Client.new(
  "https://query.wikidata.org/sparql",
  method: :get,
  headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea+wdscripts@gmail.com) Ruby 3.1" }
)

rows = sparql_client.query(query)

wikidatum_client = Wikidatum::Client.new(
  user_agent: "Connor's Random Ruby Scripts Data Fetcher",
  wikibase_url: 'https://www.wikidata.org'
)

progress_bar = ProgressBar.create(
  total: rows.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

rows.map(&:to_h).each do |row|
  # Sleep between requests so we don't hit the rate limit.
  sleep 1

  item_id = row[:item].to_s.sub('http://www.wikidata.org/entity/', '')
  item = wikidatum_client.item(id: item_id)

  item_label = item.label(lang: :en).value
  item_aliases = item.aliases(langs: [:en]).map(&:value)
  enwp_title = item.sitelink(site: :enwiki).title
  enwp_title = ERB::Util.url_encode(enwp_title.gsub(' ', '_'))

  potential_alias = pull_potential_alias_from_enwp(enwp_title)

  if potential_alias.nil?
    progress_bar.increment
    next
  end

  current_labels_and_aliases = item_aliases.push(item_label).map(&:downcase)

  # Just bail out if the item already has this name.
  if current_labels_and_aliases.include?(potential_alias.downcase)
    progress_bar.increment
    next
  end

  # If not, print the Wikidata ID and potential new name.
  progress_bar.log "Wikidata ID: #{item_id}"
  progress_bar.log "Wikidata Label: #{item_label}"
  progress_bar.log "Potential alias from Wikipedia: #{potential_alias}"
  progress_bar.log ''
  progress_bar.increment
end
