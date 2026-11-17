require './wikidata/pcgw/dumper/pcgw_metadata_importer'

# Generate a Mix'n'match catalog from the PCGamingWiki data dump.

# Mix'n'match's format requires these columns:
# - Entry ID (your alphanumeric identifier; must be unique within the catalog)
# - Entry name (will also be used for the search in mix'n'match later)
# - Entry description
# - Entry type (item identifier, e.g. "Q5"; recommended)

metadata_items = PcgwMetadataImporter.metadata_items

# Remove games that are only unique based on their letter casing.
metadata_items.uniq! { |item| item[:pcgw_id].downcase }

# An array of hashes with the necessary data.
entries = []
metadata_items.each do |item|
  # Generate a description based on the data we have.
  description = ''
  if item[:release_date].nil?
    description += 'Video game'
  else
    # Regex matching the format of dates like "September 1, 2020", "Dec 25, 2020", "April 1 2000", etc.
    if item[:release_date].match?(/\A\w+ \d{1,2},? \d{4}\z/)
      # "released on X" if release date is in the format of a specific date.
      description += "Video game released on #{item[:release_date]}"
    elsif item[:release_date].match?(/\A\d{4}\z/)
      # "released in 2020" if the release date is in the format of a year.
      description += "Video game released in #{item[:release_date]}"
    elsif item[:release_date] == 'EA'
      # Mark the video game as early access.
      description += "Video game in early access"
    elsif ['TBD', 'TBA'].include?(item[:release_date])
      # Mark it upcoming if release date is TBD or TBA.
      description += "Upcoming video game"
    else
      # Otherwise, just say the release date as "released".
      puts "Couldn't match release date format, value: #{item[:release_date]}"
      description += "Video game released #{item[:release_date]}"
    end
  end
  description += " by #{item[:developer]}" unless item[:developer].nil?
  description += "."

  entries << {
    id: item[:pcgw_id],
    title: item[:title],
    description: description,
    type: "Q7889"
  }
end

# Create lines for the TSV file.
lines = entries.map do |entry|
  entry.values_at(:id, :title, :description, :type).join("\t")
end

File.write(File.join(File.dirname(__FILE__), 'pcgw_mixnmatch.tsv'), lines.join("\n"))

