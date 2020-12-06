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

require './wikidata/pcgw/dumper/pcgw_metadata_importer'

# Import MobyGames IDs, IGDB IDs, and HLTB IDs into Wikidata by matching on their PCGW IDs.

metadata_items = PcgwMetadataImporter.metadata_items

# Run through the import with each database type.
[:mobygames, :igdb, :hltb].each do |database|
  DATABASE_ID_SYMBOL = "#{database}_id".to_sym
  puts "Importing PCGW IDs by matching #{database.capitalize} IDs on Wikidata..."

  metadata_database_ids = metadata_items.map { |hash| hash[DATABASE_ID_SYMBOL] }

  metadata_items_without_db_ids = PcgwMetadataImporter.execute_query(*PcgwMetadataImporter::PROPERTIES.values_at(:pcgw, database))
  wikidata_items = metadata_items_without_db_ids.map(&:to_h).map do |rdf|
    {
      label: rdf[:itemLabel].to_s,
      wikidata_id: rdf[:item].to_s.gsub('http://www.wikidata.org/entity/', ''),
      pcgw_id: rdf[:pcgwId].to_s
    }
  end

  # Get the number of matches based on the PCGW ID between the Wikidata query
  # response and the PCGW Dump. This causes some weird stuff later, but
  # whatever.
  metadata_items_with_db = metadata_items.select { |item| !item[DATABASE_ID_SYMBOL].nil? }.map { |item| item[:pcgw_id] }
  match_count = (wikidata_items.map { |item| item[:pcgw_id] } & metadata_items_with_db).count
  puts "Found #{match_count} PCGW IDs from PCGW Dump that are in Wikidata and do not have #{database.capitalize} IDs."

  wikidata_client = PcgwMetadataImporter.wikidata_client

  progress_bar = ProgressBar.create(
    total: match_count,
    format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
  )

  PROPERTY_ID = PcgwMetadataImporter::PROPERTIES[database][:property_id]

  wikidata_items.each do |wikidata_item|
    # Skip any records that aren't represented in the database set.
    # Not part of the initial match_count, so need to increment the progress bar.
    next unless metadata_items_with_db.include?(wikidata_item[:pcgw_id])

    progress_bar.log "Adding #{database.capitalize} ID to #{wikidata_item[:label]} (#{wikidata_item[:wikidata_id]}) based on matching PCGW ID."
    metadata_item = metadata_items.find { |metadata_item| metadata_item[:pcgw_id] == wikidata_item[:pcgw_id] }

    unless PcgwMetadataImporter.games_have_same_name?(metadata_item[:title], wikidata_item[:label])
      progress_bar.log "PCGW Title (#{metadata_item[:title]}) does not match the Wikidata item label (#{wikidata_item[:label]})"
      progress_bar.increment
      next
    end

    existing_claims = WikidataHelper.get_claims(entity: wikidata_item[:wikidata_id], property: "P#{PROPERTY_ID}")
    if existing_claims != {}
      progress_bar.log "This item already has a #{database.capitalize} ID."
      progress_bar.increment
      sleep 1
      next
    end

    wikidata_client.create_claim(wikidata_item[:wikidata_id], "value", "P#{PROPERTY_ID}", "\"#{metadata_item[DATABASE_ID_SYMBOL]}\"")
    progress_bar.log "#{wikidata_item[:wikidata_id]}: Added #{database.capitalize} ID '#{metadata_item[DATABASE_ID_SYMBOL]}'."
    sleep 2
    progress_bar.increment
  end

  progress_bar.finish unless progress_bar.finished?
end
