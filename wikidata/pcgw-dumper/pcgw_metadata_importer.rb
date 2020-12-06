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

require_relative '../wikidata_importer.rb'

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
      name: 'mobyGamesId'
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
end

metadata_items = JSON.load(File.open(File.join(File.dirname(__FILE__), 'pcgw_metadata.json')))

metadata_items.map! { |item| item.transform_keys(&:to_sym) }

steam_ids_without_pcgw_ids = PcgwMetadataImporter.execute_query(*PcgwMetadataImporter::PROPERTIES.values_at(:steam, :pcgw))

steam_ids_in_metadata = metadata_items.map { |hash| hash[:steam_id] }

steam_ids_in_wikidata = steam_ids_without_pcgw_ids.map(&:to_h).map do |rdf|
  {
    label: rdf[:itemLabel].to_s,
    wikidata_id: rdf[:item].to_s.gsub('http://www.wikidata.org/entity/', ''),
    steam_app_id: rdf[:steamId].to_s.to_i
  }
end

match_count = (steam_ids_in_wikidata.map { |hash| hash[:steam_app_id] } & steam_ids_in_metadata).count
puts "Found #{match_count} Steam IDs from PCGW Dump that are in Wikidata and do not have PCGW IDs."

wikidata_client = PcgwMetadataImporter.wikidata_client

progress_bar = ProgressBar.create(
  total: match_count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

steam_ids_in_wikidata.each do |wikidata_item|
  unless steam_ids_in_metadata.include?(wikidata_item[:steam_app_id])
    progress_bar.increment
    next
  end

  progress_bar.log "Adding PCGW ID to #{wikidata_item[:label]} (#{wikidata_item[:wikidata_id]}) based on matching Steam ID."
  metadata_item = metadata_items.find { |metadata_item| metadata_item[:steam_id] == wikidata_item[:steam_app_id] }

  unless PcgwMetadataImporter.games_have_same_name?(metadata_item[:title], wikidata_item[:label])
    progress_bar.log "PCGW Title (#{metadata_item[:title]}) does not match the Wikidata item label (#{wikidata_item[:label]})"
    progress_bar.increment
    next
  end

  existing_claims = WikidataHelper.get_claims(entity: wikidata_item[:wikidata_id], property: 'P6337')
  if existing_claims != {}
    progress_bar.log "This item already has a PCGW ID."
    progress_bar.increment
    sleep 1
    next
  end

  wikidata_client.create_claim(wikidata_item[:wikidata_id], "value", "P6337", "\"#{metadata_item[:pcgw_id]}\"")
  sleep 2
  progress_bar.increment
end

progress_bar.finish unless progress_bar.finished?
