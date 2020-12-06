require 'csv'

pcgw_games = []

CSV.foreach(
  File.join(File.dirname(__FILE__), 'pcgw_mixnmatch.tsv'),
  skip_blanks: true,
  headers: true,
  col_sep: "\t"
) do |csv_row|
  pcgw_games << {
    slug: csv_row["external_id"],
    name: csv_row["name"]
  }
end

# puts pcgw_games.inspect

File.open("pcgw_catalog2.txt", "w+") do |f|
  pcgw_games.each { |game| f.puts("#{game[:slug]}\t#{game[:name]}\tvideo game\tQ7889") }
end
