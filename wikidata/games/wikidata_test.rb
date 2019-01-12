# Gets all entity for a list of Wikidata items.
require 'open-uri'
require 'json'

wikidata_identifiers = JSON.parse(File.read('wikidata_identifiers.txt'))

wikidata_identifiers.each_with_index do |identifier, index|
  api_url = "https://www.wikidata.org/wiki/Special:EntityData/#{identifier}.json"
  response = JSON.load(open(api_url))
  File.write("identifiers/#{identifier}.json", response.to_json)
  if index > 10
    exit
  end
end
