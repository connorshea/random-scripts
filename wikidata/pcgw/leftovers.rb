# Handle leftovers with an interactive CLI that opens the PCGW and Wikidata pages in the browser for easy comparison.
require 'json'
require 'mediawiki_api'
require 'mediawiki_api/wikidata/wikidata_client'
require 'open-uri'

leftovers = JSON.load(File.read('leftovers.json'))

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

leftovers.each do |game|
  next if game['checked_for_match']
  claims = JSON.load(open("https://www.wikidata.org/w/api.php?action=wbgetclaims&entity=#{game['wikidata_item']}&property=P6337&format=json"))
  if claims["claims"] != {}
    puts "This already has a PCGW ID"
    game['checked_for_match'] = true
    next
  end
  
  puts "PCGamingWiki: #{game['pcgw']}"
  puts "Wikidata: #{game['wikidata']}"
  pcgw_url = "https://pcgamingwiki.com/wiki/#{game['pcgw_id']}"
  system("open '#{pcgw_url}'")
  wikidata_url = "https://www.wikidata.org/wiki/#{game['wikidata_item']}"
  system("open '#{wikidata_url}'")
  
  puts "Does the PCGW item match the Wikidata item? [y/n]:"
  items_match = gets.chomp

  if items_match.downcase == 'y'
    puts "Updating the wikidata item."
    wikidata_client.create_claim game['wikidata_item'], "value", "P6337", "\"#{game['pcgw_id']}\""
  end
  game['checked_for_match'] = true

  File.write('leftovers.json', leftovers.to_json)
  puts
end
