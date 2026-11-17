# frozen_string_literal: true

##
# Writes a QuickStatements batch that adds PCGamingWiki IDs (P6337) to
# Wikidata items, matching PCGamingWiki articles to items through their Steam
# application IDs (P1733).
#
# Nothing is edited and no web service is called. The inputs are files:
#
# 1. data/pcgw_games.jsonl, from pcgw_dump.rb.
# 2. wd-pcgw-ids.tsv: the result of wd-pcgw-ids.rq (every PCGamingWiki ID of
#    any rank, and every non-deprecated Steam ID, with its item).
# 3. wd-pcgw-names.tsv: the result of wd-pcgw-names.rq (en and mul labels and
#    aliases of the items that could get a PCGamingWiki ID).
#
# USAGE:
#
#   ruby pcgw_quickstatements.rb data/wd-pcgw-ids.tsv data/wd-pcgw-names.tsv [out-dir]
#
# An item gets a PCGamingWiki ID only when:
# - the item has no PCGamingWiki ID yet (of any rank),
# - its Steam IDs lead to exactly one PCGamingWiki article,
# - none of that article's Steam IDs lead to a different item, and no other
#   article lists the same Steam ID,
# - the ID isn't already on another item, and no other item in the batch
#   would get it.
#
# Candidates go to the review file instead when none of the item's en/mul
# labels or aliases match the article's name, with or without a trailing
# disambiguator like " (2016)".
#
# Each statement gets the article's MediaWiki page ID (P9675) as a
# qualifier, like almost every existing PCGamingWiki ID, and is referenced
# with stated in (P248) PCGamingWiki (Q17013880) and retrieved (P813) set to
# the day the dump was downloaded:
#
#   Q193581	P6337	"Half-Life_2"	P9675	"94"	S248	Q17013880	S813	+2026-11-16T00:00:00Z/11
#
# Writes to out-dir (default: data/):
# - pcgw-ids.qs.tsv: the batch, in the tab-separated (v1) syntax.
# - pcgw-ids-review.tsv: candidates to review, with the reason and the
#   QuickStatements command (with | in place of tabs), so approved rows can be
#   pasted into QuickStatements.
# - pcgw-ids-skipped.tsv: every other candidate that wasn't added, and why.

require 'json'
require_relative '../igdb/game_names.rb'
require_relative '../igdb/sparql_tsv.rb'

PCGW_PID = 'P6337'
PCGW_QID = 'Q17013880' # PCGamingWiki, P6337's "applicable 'stated in' value"
PAGE_ID_PID = 'P9675' # MediaWiki page ID
# Format constraint: [^\s]+
PCGW_FORMAT = /\A[^\s]+\z/

ids_path, names_path, out_dir = ARGV
abort "Usage: ruby #{File.basename(__FILE__)} wd-pcgw-ids.tsv wd-pcgw-names.tsv [out-dir]" if ids_path.nil? || names_path.nil?
out_dir ||= File.join(__dir__, 'data')
dump_path = ENV.fetch('PCGW_DUMP', File.join(__dir__, 'data', 'pcgw_games.jsonl'))
abort "#{dump_path} doesn't exist. Run pcgw_dump.rb first." unless File.exist?(dump_path)

# --- PCGamingWiki dump ---
puts "Reading #{dump_path} (downloaded #{File.mtime(dump_path).strftime('%Y-%m-%d %H:%M')})."
games_by_id = {}
game_ids_by_steam = Hash.new { |h, k| h[k] = [] }
File.foreach(dump_path) do |line|
  game = JSON.parse(line)
  name = game['page_name'].to_s
  next if name.empty?

  steam = (game['steam'] || []).map(&:to_s).select { |s| s.match?(/\A\d+\z/) }.uniq
  # "Doom (2016)" is "Doom" on Wikidata.
  names = [name, name.sub(/\s*\([^()]*\)\z/, '')].reject(&:empty?).uniq

  games_by_id[game['page_id']] = { 'page_id' => game['page_id'], 'value' => name.tr(' ', '_'), 'name' => name, 'names' => names, 'steam' => steam }
  steam.each { |id| game_ids_by_steam[id] << game['page_id'] }
end
retrieved = File.mtime(dump_path).utc.strftime('+%Y-%m-%dT00:00:00Z/11')
puts "#{games_by_id.count} PCGamingWiki articles, #{game_ids_by_steam.count} Steam IDs linked."

# --- Wikidata ---
pcgw_by_item = Hash.new { |h, k| h[k] = [] }
items_by_pcgw = Hash.new { |h, k| h[k] = [] }
steam_by_item = Hash.new { |h, k| h[k] = [] }
items_by_steam = Hash.new { |h, k| h[k] = [] }
read_sparql_tsv(ids_path).each do |row|
  qid = qid_from(row['item'])
  next if qid.nil?

  if !(value = literal_from(row['pcgw'])).empty?
    pcgw_by_item[qid] |= [value]
    items_by_pcgw[value] |= [qid]
  elsif !(value = literal_from(row['steam'])).empty?
    steam_by_item[qid] |= [value]
    items_by_steam[value] |= [qid]
  end
end
puts "Wikidata: #{pcgw_by_item.count} items with a PCGamingWiki ID, #{steam_by_item.count} with a Steam ID."

names_by_item = Hash.new { |h, k| h[k] = [] }
read_sparql_tsv(names_path).each do |row|
  qid = qid_from(row['item'])
  names_by_item[qid] |= [literal_from(row['name'])] unless qid.nil?
end

# --- Candidates ---
candidates = []
skipped = []

steam_by_item.keys.sort_by { |q| q[1..].to_i }.each do |qid|
  next if pcgw_by_item.key?(qid)

  matched = steam_by_item[qid].flat_map { |s| game_ids_by_steam[s] }.uniq
  next if matched.empty?

  if matched.length > 1
    skipped << [qid, matched.map { |id| games_by_id[id]['value'] }.join(','), 'Steam IDs lead to several PCGamingWiki articles']
    next
  end

  game = games_by_id[matched.first]
  # Another item with one of the article's Steam IDs means the item is split
  # on Wikidata, or the article covers several games.
  other_items = game['steam'].flat_map { |s| items_by_steam[s] }.uniq - [qid]
  if other_items.any?
    skipped << [qid, game['value'], "article's Steam IDs also lead to #{other_items.first(5).join(',')}"]
    next
  end

  # Other articles listing one of this article's Steam IDs. The
  # matched.length check only covers Steam IDs the item has.
  shared = game['steam'].flat_map { |s| game_ids_by_steam[s] }.uniq - [matched.first]
  if shared.any?
    skipped << [qid, game['value'], "Steam IDs shared with #{shared.first(5).map { |id| games_by_id[id]['value'] }.join(',')}"]
    next
  end

  candidates << [qid, game]
end

value_counts = candidates.map { |_, game| game['value'] }.tally
statements = []
review = []
candidates.each do |qid, game|
  value = game['value']
  command = tsv_row([qid, PCGW_PID, "\"#{value}\"", PAGE_ID_PID, "\"#{game['page_id']}\"", 'S248', PCGW_QID, 'S813', retrieved])

  if !value.match?(PCGW_FORMAT)
    skipped << [qid, value, "doesn't match the #{PCGW_PID} format constraint"]
  elsif (in_use = items_by_pcgw[value]).any?
    skipped << [qid, value, "already used on #{in_use.join(',')}"]
  elsif value_counts[value] > 1
    others = candidates.select { |_, g| g['value'] == value }.map(&:first) - [qid]
    skipped << [qid, value, "would also be added to #{others.join(',')}"]
  elsif game['names'].any? { |name| names_match?(names_by_item[qid], name) }
    statements << command
  else
    review << [qid, value, "Wikidata names don't match PCGamingWiki", game['name'],
               names_by_item[qid].first(8).join(' / '), command.tr("\t", '|')]
  end
end

# --- Write ---
batch_path = File.join(out_dir, 'pcgw-ids.qs.tsv')
review_path = File.join(out_dir, 'pcgw-ids-review.tsv')
skipped_path = File.join(out_dir, 'pcgw-ids-skipped.tsv')
File.write(batch_path, statements.map { |s| "#{s}\n" }.join)
File.write(
  review_path,
  ([tsv_row(%w[qid pcgw_id reason pcgw_name wikidata_names quickstatements])] + review.map { |r| tsv_row(r) }).join("\n") + "\n"
)
File.write(
  skipped_path,
  ([tsv_row(%w[qid pcgw_id reason])] + skipped.map { |s| tsv_row(s) }).join("\n") + "\n"
)
puts "#{statements.count} statements written to #{batch_path}."
puts "#{review.count} to review in #{review_path}."
puts "#{skipped.count} skipped, see #{skipped_path}."
