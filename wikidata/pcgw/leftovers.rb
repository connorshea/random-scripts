# Handle leftovers with an interactive CLI that opens the PCGW and Wikidata
# pages in the browser for easy comparison. It uses a JSON file in the
# format of leftovers.example.json and marks entries as "checked for match"
# whenever the game has been checked. This allows you to easily stop and start
# the script at will without needing to redo any of the checks you've already
# done.
require 'json'
require 'mediawiki_api'
require 'mediawiki_api/wikidata/wikidata_client'
require 'open-uri'

# Load the leftover games.
leftovers = JSON.load(File.read('leftovers.json'))

# Authenticate with Wikidata.
wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"]

# Go through each leftover game.
leftovers.each do |game|
  # Skip if the game has already been checked.
  next if game['checked_for_match']
  # Skip if the Wikidata item already has a PCGamingWiki ID.
  claims = JSON.load(open("https://www.wikidata.org/w/api.php?action=wbgetclaims&entity=#{game['wikidata_item']}&property=P6337&format=json"))
  if claims["claims"] != {}
    puts "This already has a PCGW ID"
    game['checked_for_match'] = true
    next
  end
  
  puts "PCGamingWiki: #{game['pcgw']}"
  puts "Wikidata: #{game['wikidata']}"
  # Open the PCGamingWiki article in the browser.
  pcgw_url = "https://pcgamingwiki.com/wiki/#{game['pcgw_id']}"
  system("open \"#{pcgw_url}\"")
  # Open the Wikidata item in the browser.
  wikidata_url = "https://www.wikidata.org/wiki/#{game['wikidata_item']}"
  system("open '#{wikidata_url}'")
  
  # Await a y/n response from the user.
  puts "Does the PCGW item match the Wikidata item? [y/n]:"
  items_match = gets.chomp

  # If the user responds with a yes, update the Wikidata item.
  if items_match.downcase == 'y'
    puts "Updating the wikidata item."
    wikidata_client.create_claim game['wikidata_item'], "value", "P6337", "\"#{game['pcgw_id']}\""
  end
  # Mark the game as checked_for_match.
  game['checked_for_match'] = true

  # Update the leftovers.json file.
  File.write('leftovers.json', leftovers.to_json)
  puts
end
