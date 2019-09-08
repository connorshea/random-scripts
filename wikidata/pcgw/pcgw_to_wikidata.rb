# Take the PCGW Steam IDs CSV and associate PCGamingWiki IDs with Wikidata
# items, then update the Wikidata item.
#http://www.rubydoc.info/github/ruby-rdf/sparql/frames

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
end

require 'json'
require 'csv'
require 'open-uri'
require "net/http"
require 'sparql/client'

# SPARQL Query to find the, pass the Steam App ID and it'll return a query
# that finds any Wikidata items with that App ID.
def query(steam_app_id)
  sparql = <<-SPARQL
    SELECT ?item ?itemLabel WHERE {
      ?item wdt:P1733 "#{steam_app_id}".
      FILTER NOT EXISTS { ?item wdt:P6337 ?pcgw_id . } # with no PCGW ID
      SERVICE wikibase:label { bd:serviceParam wikibase:language "[AUTO_LANGUAGE],en". }
    }
    LIMIT 10
  SPARQL

  return sparql
end

# Finds Wikidata items based on the Steam App ID it's passed
def find_wikidata_item_by_steam_app_id(app_id)
  endpoint = "https://query.wikidata.org/sparql"
  
  client = SPARQL::Client.new(
    "https://query.wikidata.org/sparql",
    method: :get,
    headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 2.6" }
  )
  sparql = query(app_id)
  begin
    rows = client.query(sparql)
  rescue SocketError => e
    puts e
    sleep 5
    return nil
  end

  # If there are 0 rows (no data returned) or more than one row, just skip it.
  if rows.size != 1
    print '.'
    return nil
  end
  return_row = {}
  rows.each do |row|
    return_row = { url: row.to_h[:item].to_s, title: row.to_h[:itemLabel].to_s }
  end

  return return_row
end

# Verify that the PCGW ID is valid
def verify_pcgw_url(pcgw_id)
  url = URI.parse("https://pcgamingwiki.com/wiki/#{pcgw_id}")
  req = Net::HTTP.new(url.host, url.port)
  req.use_ssl = true
  res = req.request_head(url.path)
  if res.code == "200"
    return true
  elsif res.code == "404"
    return false
  else
    return false
  end
end

pcgw_steam_ids = []

# Go through the CSV and create a hash for each PCGW item and its Steam App ID
# The CSV is in a format like this:
# Half-Life,70
# Half-Life_2,220
# Half-Life_2:_Deathmatch,320
# Half-Life_2:_Episode_One,380
# Half-Life_2:_Episode_Two,420
# Half-Life_2:_Lost_Coast,340
# Half-Life_Deathmatch:_Source,360
# Half-Life:_Blue_Shift,130
# Half-Life:_Opposing_Force,50
# Half-Life:_Source,280
CSV.foreach(
  File.join(File.dirname(__FILE__), 'pcgw_steam_ids.csv'),
  skip_blanks: true,
  headers: false,
  encoding: 'ISO-8859-1'
) do |row|
  # Skip the row if the length is >40 characters. This is a hack to get around a
  # weird issue where some game titles have really screwy encoding problems.
  next if row[0].length > 40
  pcgw_steam_ids << {
    title: row[0],
    steam_app_id: row[1]
  }
end

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

# For every PCGW item created from the CSV, find the respective wikidata item
# and then compare the id of the PCGW item and the Wikidata item found via the
# Steam App ID.
pcgw_steam_ids.each_with_index do |game, index|
  # Get the wikidata item for the current game's Steam App ID
  wikidata_item = find_wikidata_item_by_steam_app_id(game[:steam_app_id])

  # If no wikidata item is returned, skip this PCGW item.
  next if wikidata_item.nil?

  next if game[:title].encoding.to_s != "ISO-8859-1"

  puts
  puts "#{index} / #{pcgw_steam_ids.length}"
  puts "-------------"

  # Replace the underscores in the PCGW ID with spaces to get as close as possible
  # to the normal name.
  game[:pcgw_id] = game[:title].gsub(/ /, '_')

  begin
    if game[:title].downcase == wikidata_item[:title].downcase
      wikidata_id = wikidata_item[:url].sub('http://www.wikidata.org/entity/', '')
      puts "Wikidata ID: #{wikidata_id}, PCGW ID: #{game[:pcgw_id]}"

      # Check if the property already exists, and skip if it already does.
      begin
        claims = JSON.load(open("https://www.wikidata.org/w/api.php?action=wbgetclaims&entity=#{wikidata_id}&property=P6337&format=json"))
      rescue SocketError => e
        puts e
        next
      end
      if claims["claims"] != {}
        puts "This already has a PCGW ID"
        next
      end
      puts "This doesn't have a PCGW ID yet"
      
      if !verify_pcgw_url(game[:pcgw_id])
        puts "No PCGW page with the id #{game[:pcgw_id]}."
        next
      end

      wikidata_client.create_claim wikidata_id, "value", "P6337", "\"#{game[:pcgw_id]}\""
      puts "Updated #{game[:title]}: #{wikidata_item[:url]}"
    else
      puts "#{game[:title]} does not equal #{wikidata_item[:title]}"
    end
  rescue Encoding::CompatibilityError => e
    puts e
  end
  
  # Sleep for 1 second to ensure we don't get rate limited.
  sleep(1)
end
