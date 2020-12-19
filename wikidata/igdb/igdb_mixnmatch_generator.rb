require 'json'

# Generate a Mix'n'match catalog from the IGDB data dump.

# Mix'n'match's format requires these columns:
# - Entry ID (your alphanumeric identifier; must be unique within the catalog)
# - Entry name (will also be used for the search in mix'n'match later)
# - Entry description
# - Entry type (item identifier, e.g. "Q5"; recommended)

igdb_games = JSON.load(File.open(File.join(File.dirname(__FILE__), 'igdb_games.json'))).map do |game|
  game.transform_keys(&:to_sym)
end

puts "#{igdb_games.count} games!"

# An array of hashes with the necessary data.
entries = []
igdb_games.each do |game|
  # Generate a description based on the data we have.
  description = ''
  # Use the release year if the release date exists, otherwise skip it.
  if game[:first_release_date].nil?
    description += 'Video game'
  else
    description += "#{Time.at(game[:first_release_date]).year} video game"
  end
  # Add the platforms that the game supports, if any.
  description += " for #{game[:platforms].first(3).join(', ')}" unless game[:platforms].count.zero?
  # Add the names of the first 2 involved companies in the list.
  description += " by #{game[:involved_companies].first(2).join(' and ')}" unless game[:involved_companies].count.zero?
  description += "."

  entries << {
    id: game[:slug],
    title: game[:name],
    description: description,
    type: "Q7889"
  }
end

# Create lines for the TSV file.
lines = entries.map do |entry|
  entry.values_at(:id, :title, :description, :type).join("\t")
end

File.write(File.join(File.dirname(__FILE__), 'igdb_mixnmatch.tsv'), lines.join("\n"))

