# frozen_string_literal: true

##
# Writes a QuickStatements batch that adds platform (P400) statements to
# video games on Wikidata that have a Steam application ID (P1733) but no
# platform statement, using the platforms Steam lists for the app.
#
# Nothing is edited and no web service is called. The inputs are files:
#
# 1. wd-steam-no-platform.tsv: the result of wd-steam-no-platform.rq (every
#    instance of video game with a non-deprecated Steam ID and no P400
#    statement of any rank), saved as TSV from QLever.
# 2. data/steam_platforms.jsonl: the platforms Steam lists for each app,
#    fetched with steam_platforms_fetch.rb.
#
# USAGE:
#
#   ruby steam_platforms_quickstatements.rb data/wd-steam-no-platform.tsv [out-dir]
#
# Platforms are only ever Windows (Q1406), macOS (Q14116) and Linux (Q388).
# Each statement is referenced with stated in (P248) Steam (Q337535), the
# Steam application ID it came from, and retrieved (P813), the date the
# platforms were fetched:
#
#   Q123	P400	Q1406	S248	Q337535	S1733	"211740"	S813	+2026-11-15T00:00:00Z/11
#
# An item with several Steam IDs gets the platforms of all of them, and each
# statement is referenced with every Steam ID that lists that platform.
#
# Writes to out-dir (default: data/):
# - steam-platforms.qs.tsv: the batch, in the tab-separated (v1) syntax.
# - steam-platforms-ids-to-check.txt: Steam IDs whose platforms haven't been
#   fetched. Run `ruby steam_platforms_fetch.rb data/steam-platforms-ids-to-check.txt`,
#   then this again.
# - steam-platforms-skipped.tsv: items that weren't added, and why.

require_relative './steam_platforms.rb'
require_relative './sparql_tsv.rb'

STEAM_PID = 'P1733'
PLATFORM_PID = 'P400'
RETRIEVED_PID = 'P813'
STATED_IN_PID = 'P248'
STEAM_QID = 'Q337535'
# Steam application ID format constraint.
STEAM_FORMAT = /\A[1-9]\d{0,6}\z/

input_path, out_dir = ARGV
abort "Usage: ruby #{File.basename(__FILE__)} wd-steam-no-platform.tsv [out-dir]" if input_path.nil?
out_dir ||= File.join(__dir__, 'data')

steam_ids_by_item = Hash.new { |h, k| h[k] = [] }
read_sparql_tsv(input_path).each do |row|
  qid = qid_from(row['item'])
  steam = literal_from(row['steam'])
  steam_ids_by_item[qid] |= [steam] unless qid.nil? || steam.empty?
end
puts "#{steam_ids_by_item.count} items with a Steam ID and no platform."

platforms = SteamPlatforms.load
retrieved = SteamPlatforms.load_retrieved
puts "Platforms fetched for #{platforms.count} Steam apps."

commands = []
skipped = []
to_check = []
steam_ids_by_item.keys.sort_by { |q| q[1..].to_i }.each do |qid|
  ids = steam_ids_by_item[qid]
  invalid = ids.reject { |id| id.match?(STEAM_FORMAT) }
  if invalid.any?
    skipped << [qid, ids.join(','), "Steam ID #{invalid.join(',')} doesn't match the format constraint"]
    next
  end

  missing = ids.reject { |id| platforms.key?(id) }
  if missing.any?
    to_check.concat(missing)
    skipped << [qid, ids.join(','), 'platforms not fetched yet, run steam_platforms_fetch.rb']
    next
  end

  # Platform QID => Steam IDs that list it.
  sources = Hash.new { |h, k| h[k] = [] }
  ids.each { |id| (platforms[id] || []).each { |platform| sources[platform] << id } }
  if sources.empty?
    reason = ids.all? { |id| platforms[id].nil? } ? "Steam didn't return the app" : 'Steam lists no platforms'
    skipped << [qid, ids.join(','), reason]
    next
  end

  SteamPlatforms::PLATFORM_QIDS.values.each do |platform|
    sources[platform].each do |id|
      date = "+#{retrieved.fetch(id)}T00:00:00Z/11"
      # A second command with the same value adds its reference to the
      # statement the first one created.
      commands << tsv_row([qid, PLATFORM_PID, platform, STATED_IN_PID.sub('P', 'S'), STEAM_QID, STEAM_PID.sub('P', 'S'), "\"#{id}\"", RETRIEVED_PID.sub('P', 'S'), date])
    end
  end
end

batch_path = File.join(out_dir, 'steam-platforms.qs.tsv')
to_check_path = File.join(out_dir, 'steam-platforms-ids-to-check.txt')
skipped_path = File.join(out_dir, 'steam-platforms-skipped.tsv')
File.write(batch_path, commands.map { |c| "#{c}\n" }.join)
File.write(to_check_path, to_check.uniq.map { |id| "#{id}\n" }.join)
File.write(skipped_path, ([tsv_row(%w[qid steam_ids reason])] + skipped.map { |s| tsv_row(s) }).join("\n") + "\n")

puts "#{commands.count} platform statements for #{commands.map { |c| c.split("\t").first }.uniq.count} items written to #{batch_path}."
if to_check.any?
  puts "#{to_check.uniq.count} Steam apps need their platforms fetched: " \
       "run `ruby steam_platforms_fetch.rb #{to_check_path}`, then this again."
end
puts "#{skipped.count} skipped, see #{skipped_path}."
