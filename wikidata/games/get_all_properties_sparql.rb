require 'sparql/client'
require 'json'

endpoint = "https://query.wikidata.org/sparql"

def query(item)
  sparql = <<-SPARQL
    PREFIX entity: <http://www.wikidata.org/entity/>

    SELECT ?propNumber ?propLabel ?val ?valUrl
    WHERE
    {
      hint:Query hint:optimizer 'None' .
      {	BIND(entity:#{item} AS ?valUrl) .
        BIND("N/A" AS ?propUrl ) .
        BIND("Name"@en AS ?propLabel ) .
          entity:#{item} rdfs:label ?val .
          
            FILTER (LANG(?val) = "en") 
      }
        UNION
        {   BIND(entity:#{item} AS ?valUrl) .
          
            BIND("AltLabel"@en AS ?propLabel ) .
            optional{entity:#{item} skos:altLabel ?val}.
            FILTER (LANG(?val) = "en") 
        }
        UNION
        {   BIND(entity:#{item} AS ?valUrl) .
          
            BIND("description"@en AS ?propLabel ) .
            optional{entity:#{item} schema:description ?val}.
            FILTER (LANG(?val) = "en") 
        }
        UNION
      {	entity:#{item} ?propUrl ?valUrl .
        ?property ?ref ?propUrl .
        ?property rdf:type wikibase:Property .
        ?property rdfs:label ?propLabel.
          FILTER (lang(?propLabel) = 'en' )
            filter  isliteral(?valUrl) 
            BIND(?valUrl AS ?val)
      }
      UNION
      {	entity:#{item} ?propUrl ?valUrl .
        ?property ?ref ?propUrl .
        ?property rdf:type wikibase:Property .
        ?property rdfs:label ?propLabel.
          FILTER (lang(?propLabel) = 'en' ) 
            filter  isIRI(?valUrl) 
            ?valUrl rdfs:label ?valLabel 
        FILTER (LANG(?valLabel) = "en") 
            BIND(CONCAT(?valLabel) AS ?val)
      }
            BIND( SUBSTR(str(?propUrl),38, 250) AS ?propNumber)
    }
    ORDER BY xsd:integer(?propNumber)
    
  SPARQL

  return sparql
end

client = SPARQL::Client.new(endpoint, :method => :get)
rows = []

sparql = query('Q76255')
rows << client.query(sparql)

props = []

rows.each do |row|
  prop = {}

  row.each do |key|
    key_hash = key.to_h
    puts "#{key_hash[:propLabel].to_s} (#{key_hash[:propNumber].to_s}): #{key_hash[:val].to_s}"
    valUrl = key_hash[:valUrl].to_s
    puts valUrl if valUrl.start_with?('http://www.wikidata.org')
    next if row.to_s == ""
    prop[key] = row.to_s
  end
  props << prop
end

# puts props.inspect
