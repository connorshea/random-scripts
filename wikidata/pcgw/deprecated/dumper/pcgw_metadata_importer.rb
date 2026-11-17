require_relative '../../wikidata_importer.rb'

class PcgwMetadataImporter < WikidataImporter
  PROPERTIES = {
    pcgw: {
      property_id: 6337,
      name: 'pcgwId'
    },
    steam: {
      property_id: 1733,
      name: 'steamId'
    },
    mobygames: {
      property_id: 1933,
      name: 'mobygamesId'
    },
    igdb: {
      property_id: 5794,
      name: 'igdbId'
    },
    hltb: {
      property_id: 2816,
      name: 'hltbId'
    }
  }

  # Create a query for getting all video game items on Wikidata with an X property
  # and no Y property.
  #
  # @param with_property_hash [Hash] A hash with a `property_id` (e.g. 123) and `name`.
  # @param without_property_hash [Hash] A hash with a `property_id` (e.g. 123) and `name`.
  # @return [String] The generated SPARQL query for using with Wikidata's SPARQL endpoint.
  def self.query(with_property_hash, without_property_hash)
    with_id, with_id_name = with_property_hash.values_at(:property_id, :name)
    without_id, without_id_name = without_property_hash.values_at(:property_id, :name)

    return <<~SPARQL
      SELECT ?item ?itemLabel ?#{with_id_name}
      {
        ?item wdt:P31 wd:Q7889;
              wdt:P#{with_id} ?#{with_id_name}.
        FILTER NOT EXISTS { ?item wdt:P#{without_id} ?#{without_id_name} . }
        SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
      }
    SPARQL
  end

  def self.metadata_items
    JSON.load(File.open(File.join(File.dirname(__FILE__), 'pcgw_metadata.json'))).map do |item|
      item.transform_keys(&:to_sym)
    end
  end
end
