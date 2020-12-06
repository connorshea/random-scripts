require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'mediawiki_api', require: true
  gem 'mediawiki_api-wikidata', git: 'https://github.com/wmde/WikidataApiGem.git'
  gem 'sparql-client'
  gem 'addressable'
  gem 'ruby-progressbar', '~> 1.10'
  gem 'pry'
end

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
    JSON.load(File.open(File.join(File.dirname(__FILE__), '../pcgw_metadata.json'))).map do |item|
      item.transform_keys(&:to_sym)
    end
  end
end

metadata_items = PcgwMetadataImporter.metadata_items

# Get the number of matches for IDs that can be imported from PCGamingWiki.
[:steam, :hltb, :mobygames, :igdb].each do |database|
  pcgw_ids_without_db_ids = PcgwMetadataImporter.execute_query(*PcgwMetadataImporter::PROPERTIES.values_at(:pcgw, database))

  wikidata_items = pcgw_ids_without_db_ids.map(&:to_h).map do |rdf|
    {
      label: rdf[:itemLabel].to_s,
      wikidata_id: rdf[:item].to_s.gsub('http://www.wikidata.org/entity/', ''),
      pcgw_id: rdf[:pcgwId].to_s
    }
  end

  metadata_items_with_db = metadata_items.select { |item| !item["#{database}_id".to_sym].nil? }
  match_count = (wikidata_items.map { |item| item[:pcgw_id] } & metadata_items_with_db.map { |item| item[:pcgw_id] }).count

  puts "Matches for #{database.capitalize}: #{match_count}"
end
