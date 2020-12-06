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

# Import PCGW IDs into Wikidata by matching them based on their Steam IDs,
# MobyGames IDs, IGDB IDs, and HLTB IDs.
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

metadata_items = PcgwMetadataImporter.metadata_items

# Run through the import with each database type.
[:steam, :mobygames, :igdb, :hltb].each do |database|
  puts "Importing PCGW IDs by matching #{database.capitalize} IDs on Wikidata..."

  metadata_database_ids = metadata_items.map { |hash| hash["#{database}_id".to_sym] }

  database_ids_without_pcgw_ids = PcgwMetadataImporter.execute_query(*PcgwMetadataImporter::PROPERTIES.values_at(database, :pcgw))
  wikidata_database_ids = database_ids_without_pcgw_ids.map(&:to_h).map do |rdf|
    database_id = rdf["#{database}Id".to_sym].to_s
    # Convert it to an integer if the value looks like one.
    database_id = database_id.to_i if database_id.match?(/\d+/)
    {
      label: rdf[:itemLabel].to_s,
      wikidata_id: rdf[:item].to_s.gsub('http://www.wikidata.org/entity/', ''),
      "#{database}_id": database_id
    }.transform_keys(&:to_sym)
  end

  # Get the number of matches based on this ID between the Wikidata query
  # response and the PCGW Dump. This causes some weird stuff later, but
  # whatever.
  match_count = (wikidata_database_ids.map { |hash| hash["#{database}_id".to_sym] } & metadata_database_ids).count
  puts "Found #{match_count} #{database.capitalize} IDs from PCGW Dump that are in Wikidata and do not have PCGW IDs."

  wikidata_client = PcgwMetadataImporter.wikidata_client

  progress_bar = ProgressBar.create(
    total: match_count,
    format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
  )

  wikidata_database_ids.each do |wikidata_item|
    # Skip any records that aren't represented in the database set.
    # Not part of the initial match_count, so need to increment the progress bar.
    next unless metadata_database_ids.include?(wikidata_item["#{database}_id".to_sym])

    progress_bar.log "Adding PCGW ID to #{wikidata_item[:label]} (#{wikidata_item[:wikidata_id]}) based on matching #{database.capitalize} ID."
    metadata_item = metadata_items.find { |metadata_item| metadata_item["#{database}_id".to_sym] == wikidata_item["#{database}_id".to_sym] }

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
end
