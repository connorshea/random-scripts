require 'open-uri'
require 'json'

engines = []

api_url = 'https://pcgamingwiki.com/w/api.php?action=askargs&conditions=Category:Engines&printouts=Wikipedia&parameters=limit=500&format=json'
engines_json = JSON.load(open(api_url))

engines_json['query']['results'].each do |name, engine|
  engine_object = {}

  engine_object[:pcgw_name] = engine['fulltext']
  engine_object[:pcgw_url] = engine['fullurl']
  engine_object[:wikipedia] = engine['printouts']['Wikipedia'].first
  engine_object[:wikipedia_url] = engine_object[:wikipedia].nil? ? nil : "https://en.wikipedia.org/wiki/#{engine_object[:wikipedia].gsub(' ', '_')}"

  engines << engine_object
end

File.write('pcgw_engines_list.json', JSON.pretty_generate(engines))
