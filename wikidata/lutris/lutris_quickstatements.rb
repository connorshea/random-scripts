# frozen_string_literal: true

##
# Writes a QuickStatements batch that adds Lutris game IDs (P7597) to
# Wikidata items, matching Lutris games to items through the IGDB game IDs
# (P5794) and Steam application IDs (P1733) that Lutris links each game to
# (its "provider_games").
#
# Nothing is edited and no web service is called. The inputs are files:
#
# 1. data/lutris_games.jsonl, from lutris_dump.rb.
# 2. wd-lutris-ids.tsv: the result of wd-lutris-ids.rq (every Lutris ID of
#    any rank, and every non-deprecated IGDB and Steam ID, with its item).
# 3. wd-lutris-names.tsv: the result of wd-lutris-names.rq (en and mul
#    labels and aliases of the items that could get a Lutris ID).
#
# USAGE:
#
#   ruby lutris_quickstatements.rb data/wd-lutris-ids.tsv data/wd-lutris-names.tsv [out-dir]
#
# An item gets a Lutris ID only when:
# - the item has no Lutris ID yet (of any rank),
# - its IGDB and Steam IDs together lead to exactly one Lutris game,
# - none of that Lutris game's IGDB or Steam links lead to a different item,
#   and no other Lutris game links to the same IGDB or Steam ID,
# - the Lutris slug isn't already on another item, and no other item in the
#   batch would get it,
# - the slug matches the P7597 format constraint.
#
# These send the candidate to the review file instead:
# - none of the item's en/mul labels or aliases match the Lutris game's
#   name, its aliases, or the names of its IGDB and Steam links,
# - the item and the Lutris game both have IGDB IDs (or both have Steam IDs)
#   but don't share one.
#
# Lutris games with change_for set are pending edits to another game, not
# games, and are ignored.
#
# Each statement is referenced with stated in (P248) Lutris (Q75129027) and
# retrieved (P813) set to the day the dump was downloaded:
#
#   Q117809	P7597	"kalonline"	S248	Q75129027	S813	+2026-11-16T00:00:00Z/11
#
# Writes to out-dir (default: data/):
# - lutris-ids.qs.tsv: the batch, in the tab-separated (v1) syntax.
# - lutris-ids-review.tsv: candidates to review, with the reason and the
#   QuickStatements command, so approved rows can be copied into the batch.
# - lutris-ids-skipped.tsv: every other candidate that wasn't added, and why.

require 'json'
require_relative '../igdb/game_names.rb'
require_relative '../igdb/sparql_tsv.rb'

LUTRIS_PID = 'P7597'
LUTRIS_QID = 'Q75129027' # Lutris game database, P7597's "applicable 'stated in' value"
# Format constraint: ^[\-]?[a-z\d]+([\-]{1,2}[a-z\d]+)*[\-]?$. Possessive so
# a long non-match can't backtrack.
LUTRIS_FORMAT = /\A-?[a-z\d]++(?:-{1,2}[a-z\d]++)*+-?\z/

ids_path, names_path, out_dir = ARGV
abort "Usage: ruby #{File.basename(__FILE__)} wd-lutris-ids.tsv wd-lutris-names.tsv [out-dir]" if ids_path.nil? || names_path.nil?
out_dir ||= File.join(__dir__, 'data')
dump_path = ENV.fetch('LUTRIS_DUMP', File.join(__dir__, 'data', 'lutris_games.jsonl'))
abort "#{dump_path} doesn't exist. Run lutris_dump.rb first." unless File.exist?(dump_path)

# --- Lutris dump ---
puts "Reading #{dump_path} (downloaded #{File.mtime(dump_path).strftime('%Y-%m-%d %H:%M')})."
lutris_by_id = {}
lutris_ids_by_igdb = Hash.new { |h, k| h[k] = [] }
lutris_ids_by_steam = Hash.new { |h, k| h[k] = [] }
pending_edits = 0
File.foreach(dump_path) do |line|
  game = JSON.parse(line)
  unless game['change_for'].nil?
    pending_edits += 1
    next
  end

  providers = game['provider_games'] || []
  igdb = providers.select { |p| p['service'] == 'igdb' }.map { |p| p['slug'].to_s }.reject(&:empty?).uniq
  steam = providers.select { |p| p['service'] == 'steam' }.map { |p| p['slug'].to_s }.select { |s| s.match?(/\A\d+\z/) }.uniq
  # Aliases may be strings or objects with a name.
  aliases = (game['aliases'] || []).map { |a| a.is_a?(Hash) ? a['name'] : a }.compact
  names = ([game['name']] + aliases + providers.select { |p| %w[igdb steam].include?(p['service']) }.map { |p| p['name'] })
          .map(&:to_s).reject(&:empty?).uniq

  lutris_by_id[game['id']] = { 'slug' => game['slug'], 'name' => game['name'], 'names' => names, 'igdb' => igdb, 'steam' => steam }
  igdb.each { |slug| lutris_ids_by_igdb[slug] << game['id'] }
  steam.each { |id| lutris_ids_by_steam[id] << game['id'] }
end
retrieved = File.mtime(dump_path).utc.strftime('+%Y-%m-%dT00:00:00Z/11')
puts "#{lutris_by_id.count} Lutris games (#{pending_edits} pending edits ignored), " \
     "#{lutris_ids_by_igdb.count} IGDB and #{lutris_ids_by_steam.count} Steam IDs linked."

# --- Wikidata ---
lutris_by_item = Hash.new { |h, k| h[k] = [] }
items_by_lutris = Hash.new { |h, k| h[k] = [] }
igdb_by_item = Hash.new { |h, k| h[k] = [] }
steam_by_item = Hash.new { |h, k| h[k] = [] }
items_by_igdb = Hash.new { |h, k| h[k] = [] }
items_by_steam = Hash.new { |h, k| h[k] = [] }
read_sparql_tsv(ids_path).each do |row|
  qid = qid_from(row['item'])
  next if qid.nil?

  if !(value = literal_from(row['lutris'])).empty?
    lutris_by_item[qid] |= [value]
    items_by_lutris[value] |= [qid]
  elsif !(value = literal_from(row['igdb'])).empty?
    igdb_by_item[qid] |= [value]
    items_by_igdb[value] |= [qid]
  elsif !(value = literal_from(row['steam'])).empty?
    steam_by_item[qid] |= [value]
    items_by_steam[value] |= [qid]
  end
end
puts "Wikidata: #{lutris_by_item.count} items with a Lutris ID, #{igdb_by_item.count} with an IGDB ID, #{steam_by_item.count} with a Steam ID."

names_by_item = Hash.new { |h, k| h[k] = [] }
read_sparql_tsv(names_path).each do |row|
  qid = qid_from(row['item'])
  names_by_item[qid] |= [literal_from(row['name'])] unless qid.nil?
end

# --- Candidates ---
candidates = []
skipped = []

(igdb_by_item.keys | steam_by_item.keys).sort_by { |q| q[1..].to_i }.each do |qid|
  next if lutris_by_item.key?(qid)

  igdb = igdb_by_item[qid]
  steam = steam_by_item[qid]
  matched = (igdb.flat_map { |s| lutris_ids_by_igdb[s] } + steam.flat_map { |s| lutris_ids_by_steam[s] }).uniq
  next if matched.empty?

  if matched.length > 1
    skipped << [qid, matched.map { |id| lutris_by_id[id]['slug'] }.join(','), 'IGDB/Steam IDs lead to several Lutris games']
    next
  end

  game = lutris_by_id[matched.first]
  # Every item the Lutris game's links lead to. Another one means the item is
  # split on Wikidata, or Lutris merged two games.
  other_items = (game['igdb'].flat_map { |s| items_by_igdb[s] } + game['steam'].flat_map { |s| items_by_steam[s] }).uniq - [qid]
  if other_items.any?
    skipped << [qid, game['slug'], "Lutris game's IGDB/Steam links also lead to #{other_items.first(5).join(',')}"]
    next
  end

  # Other Lutris games sharing one of this game's links. Usually duplicates on
  # Lutris; the matched.length check only covers links the item has.
  shared = (game['igdb'].flat_map { |s| lutris_ids_by_igdb[s] } + game['steam'].flat_map { |s| lutris_ids_by_steam[s] }).uniq - [matched.first]
  if shared.any?
    skipped << [qid, game['slug'], "IGDB/Steam links shared with Lutris #{shared.first(5).map { |id| lutris_by_id[id]['slug'] }.join(',')}"]
    next
  end

  candidates << [qid, game]
end

slug_counts = candidates.map { |_, game| game['slug'] }.tally
statements = []
review = []
candidates.each do |qid, game|
  value = game['slug']
  command = tsv_row([qid, LUTRIS_PID, "\"#{value}\"", 'S248', LUTRIS_QID, 'S813', retrieved])

  if !value.match?(LUTRIS_FORMAT)
    skipped << [qid, value, "doesn't match the #{LUTRIS_PID} format constraint"]
  elsif (in_use = items_by_lutris[value]).any?
    skipped << [qid, value, "already used on #{in_use.join(',')}"]
  elsif slug_counts[value] > 1
    others = candidates.select { |_, g| g['slug'] == value }.map(&:first) - [qid]
    skipped << [qid, value, "would also be added to #{others.join(',')}"]
  else
    reasons = []
    reasons << "Wikidata names don't match Lutris" unless game['names'].any? { |name| names_match?(names_by_item[qid], name) }
    if igdb_by_item[qid].any? && game['igdb'].any? && (igdb_by_item[qid] & game['igdb']).empty?
      reasons << "IGDB IDs differ (Lutris: #{game['igdb'].join(',')})"
    end
    if steam_by_item[qid].any? && game['steam'].any? && (steam_by_item[qid] & game['steam']).empty?
      reasons << "Steam IDs differ (Lutris: #{game['steam'].join(',')})"
    end

    if reasons.empty?
      statements << command
    else
      review << [qid, value, reasons.join('; '), game['name'], names_by_item[qid].first(8).join(' / '), command.tr("\t", '|')]
    end
  end
end

# --- Write ---
batch_path = File.join(out_dir, 'lutris-ids.qs.tsv')
review_path = File.join(out_dir, 'lutris-ids-review.tsv')
skipped_path = File.join(out_dir, 'lutris-ids-skipped.tsv')
File.write(batch_path, statements.map { |s| "#{s}\n" }.join)
File.write(
  review_path,
  ([tsv_row(%w[qid lutris_slug reason lutris_name wikidata_names quickstatements])] + review.map { |r| tsv_row(r) }).join("\n") + "\n"
)
File.write(
  skipped_path,
  ([tsv_row(%w[qid lutris_slug reason])] + skipped.map { |s| tsv_row(s) }).join("\n") + "\n"
)
puts "#{statements.count} statements written to #{batch_path}."
puts "#{review.count} to review in #{review_path}."
puts "#{skipped.count} skipped, see #{skipped_path}."
