#
# Using the esrb_dump.json, generate a CSV file for mix'n'match.

require 'json'
require 'csv'

# Returns a humanized string for a given array.
def to_sentence(array)
  case array.length
  when 0
    ""
  when 1
    "#{array[0]}"
  when 2
    "#{array[0]} and #{array[1]}"
  else
    "#{array[0...-1].join(', ')}, and #{array[-1]}"
  end
end

esrb_dump = JSON.parse(File.read('wikidata/esrb/esrb_dump.json'))

PLATFORM_MAPPING = {
  'Windows PC' => 'Windows',
  'PlayStation/PS one' => 'PlayStation'
}.freeze

esrb_dump.map! do |esrb_game|
  # Remove copyright symbols and other noise.
  title = esrb_game['title'].gsub(/®|©|™/, '').strip

  # Change the platform names for platforms with weird names in the ESRB Database.
  platforms = esrb_game['platforms'].split(', ').map do |platform|
    if PLATFORM_MAPPING.key?(platform)
      PLATFORM_MAPPING[platform]
    else
      platform
    end
  end.uniq

  descriptors = esrb_game['descriptors'].split(', ')
  descriptors = nil if descriptors == ['No Descriptors']

  {
    esrb_id: esrb_game['certificateId'],
    title: title,
    publisher: esrb_game['publisher'],
    rating: esrb_game['rating'],
    platforms: platforms,
    descriptors: descriptors
  }
end

# puts JSON.pretty_generate(esrb_dump)

def generate_description(game)
  "Video game published by #{game[:publisher]} for #{to_sentence(game[:platforms])}."
end

csv_contents = CSV.generate(col_sep: "\t") do |csv|
  # Add headers
  csv << ['id', 'name', 'desc']

  # Add game rows
  esrb_dump.each do |game|
    csv << [
      game[:esrb_id],
      game[:title],
      generate_description(game)
    ]
  end
end

# Write the generated CSV to a file.
File.write('wikidata/esrb/esrb_dump.tsv', csv_contents)
