# Given a chunk of Wikidata IDs, get all the games from the vglist_games.json
# dump. Then filter down to just the ones with QIDs from `chunk.txt`.
# Then check if they have "Edition" in their title.
#
# Then print a list of all of those games with "Edition" in the title and
# their Wikidata URL.

require 'json'

vglist_games = JSON.parse(File.read('vglist_games.json'))

# Get the Wikidata IDs from the chunk.
wikidata_ids = File.read('chunk.txt').split("\n")

# Filter down to just the games that have Wikidata IDs from the chunk.
vglist_games = vglist_games.select { |game| wikidata_ids.include?("Q#{game['wikidata_id']}") }

vglist_games_with_editions = []

vglist_games.each do |game|
  # Use a regex to check if the game has "Edition" in the title, case-insensitive.
  if game['name'] =~ / edition/i
    vglist_games_with_editions << game
  end
end

vglist_games_with_editions.each do |game|
  puts "* '#{game['name']}': https://www.wikidata.org/wiki/Q#{game['wikidata_id']}"
end
