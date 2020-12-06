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

require_relative '../pcgw_metadata_importer.rb'

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
