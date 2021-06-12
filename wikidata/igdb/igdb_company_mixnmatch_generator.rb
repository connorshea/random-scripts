require 'json'

# Generate a Mix'n'match catalog from the IGDB company data dump.

# Mix'n'match's format requires these columns:
# - Entry ID (your alphanumeric identifier; must be unique within the catalog)
# - Entry name (will also be used for the search in mix'n'match later)
# - Entry description
# - Entry type (item identifier, e.g. "Q5"; recommended)

igdb_companies = JSON.load(File.open(File.join(File.dirname(__FILE__), 'igdb_companies.json'))).map do |game|
  game.transform_keys(&:to_sym)
end

puts "#{igdb_companies.count} companies!"

# An array of hashes with the necessary data.
entries = []
igdb_companies.each do |company|
  # Generate a description based on the data we have.
  description = 'Video game'
  if !company[:developed].empty? && !company[:published].empty?
    description += ' developer and publisher'
  elsif !company[:developed].empty?
    description += ' developer'
  elsif !company[:published].empty?
    description += ' publisher'
  else
    description += ' company'
  end
  # Use the developed games if they exist, otherwise skip it.
  if !company[:developed].empty? && !company[:published].empty?
    description += " that developed #{company[:developed].join(', ')} and published #{company[:published].join(', ')}"
  elsif !company[:developed].empty?
    description += " that developed #{company[:developed].join(', ')}"
  elsif !company[:published].empty?
    description += " that published #{company[:published].join(', ')}"
  end
  description += "."

  entries << {
    id: company[:slug],
    title: company[:name],
    description: description,
    type: "Q210167"
  }
end

# Create lines for the TSV file.
lines = entries.map do |entry|
  entry.values_at(:id, :title, :description, :type).join("\t")
end

File.write(File.join(File.dirname(__FILE__), 'igdb_company_mixnmatch.tsv'), lines.join("\n"))

