# This script generates a SPARQL Query that can be used on
# https://query.wikidata.org to detect Wikidata IDs on vglist that are
# redirects. This could be integrated into vglist itself in the future and used
# to automatically delete any games with no owners that have a redirecting
# Wikidata ID. The remaining problematic game records would need to be resolved
# manually.
#
# It requires that vglist.rb be run first to generate the vglist_games.json
# file.

require 'json'

vglist_games = JSON.parse(File.read('vglist_games.json'))

wikidata_ids = vglist_games.map { |game| game['wikidata_id'] }

wikidata_ids.map! { |id| "wd:Q#{id}" }

puts <<~SPARQL
SELECT ?item ?itemLabel ?target ?targetLabel WHERE {
  VALUES ?item { #{wikidata_ids.join(' ')} }
         ?item owl:sameAs ?target .
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
SPARQL
