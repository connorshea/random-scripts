# frozen_string_literal: true

##
# Writes a QuickStatements 3.0 batch that adds vglist game IDs (P8351) to
# Wikidata items, based on the Wikidata IDs stored on vglist games.
#
# Nothing is edited and no web service is called. The inputs are files:
#
# 1. The games JSON export from the vglist admin portal, e.g.
#    vglist-games-2026-11-14.json:
#      { "exported_at": "...", "games": [{ "id": 1, "name": "...", "steam_app_ids": [...], "wikidata_id": 2374 }, ...] }
# 2. wd-vglist-ids.tsv: the result of wd-vglist-ids.rq (every P8351 value on
#    Wikidata and the item it's on), saved as TSV from QLever or the Wikidata
#    Query Service.
# 3. wd-video-games-no-vglist.tsv: the result of wd-video-games-no-vglist.rq
#    (video games with no vglist ID, with their English or mul label).
#
# USAGE:
#
#   ruby vglist.rb vglist-games-2026-11-14.json wd-vglist-ids.tsv wd-video-games-no-vglist.tsv [out-dir]
#
# A game is added when:
# - its Wikidata item is in wd-video-games-no-vglist.tsv (so it exists, isn't
#   a redirect, is a video game and has no vglist ID),
# - no other vglist game points at the same item,
# - its vglist ID isn't already on some Wikidata item,
# - the item's label matches the vglist name (see games_have_same_name?).
#
# Writes to out-dir (default: the current directory):
# - vglist-ids.qs.tsv: the QuickStatements batch, in the tab-separated
#   (v1) command syntax that QuickStatements 3.0 takes. If it has more than
#   CHUNK_SIZE lines (default 20000), it's split into vglist-ids.001.qs.tsv,
#   vglist-ids.002.qs.tsv, ... instead, since QuickStatements won't take
#   very large batches.
# - vglist-name-mismatches.tsv: games that could be matched by Wikidata ID but
#   whose name differs from the Wikidata label, for manual review.
# - vglist-skipped.tsv: every other game with a Wikidata ID that wasn't added,
#   and why.

require 'json'
require 'rubygems/text'

def games_have_same_name?(name1, name2)
  name1 = name1.downcase
  name2 = name2.downcase
  return true if name1 == name2

  levenshtein = Class.new.extend(Gem::Text).method(:levenshtein_distance)
  return true if levenshtein.call(name1, name2) <= 2

  replacements = [
    { before: '&', after: 'and' },
    { before: 'deluxe', after: '' },
    { before: ' (video game)', after: '' },
  ]
  replacements.each do |replacement|
    name1 = name1.gsub(replacement[:before], replacement[:after]).strip
    name2 = name2.gsub(replacement[:before], replacement[:after]).strip
  end

  name1 == name2
end

# Reads a SPARQL TSV result (QLever or WDQS) into an array of hashes keyed by
# variable name without the "?".
def read_sparql_tsv(path)
  lines = File.readlines(path, chomp: true)
  header = lines.shift.split("\t").map { |h| h.delete_prefix('?') }
  lines.reject(&:empty?).map { |line| header.zip(line.split("\t", -1)).to_h }
end

# "<http://www.wikidata.org/entity/Q123>" or "http://...Q123" -> "Q123"
def qid_from(value)
  value.to_s[/Q\d+(?=>?\z)/]
end

# "\"Some \\\"name\\\"\"@en" -> "Some \"name\""; bare values come back as-is.
def literal_from(value)
  value = value.to_s
  match = value.match(/\A"(.*)"(?:@[\w-]+|\^\^.+)?\z/m)
  return value if match.nil?

  match[1].gsub(/\\(.)/) do
    case Regexp.last_match(1)
    when 't' then "\t"
    when 'n' then "\n"
    when 'r' then "\r"
    else Regexp.last_match(1)
    end
  end
end

def tsv_row(values)
  values.map { |v| v.to_s.gsub(/\s/, ' ') }.join("\t")
end

vglist_path, vglist_ids_path, candidates_path, out_dir = ARGV
if vglist_path.nil? || vglist_ids_path.nil? || candidates_path.nil?
  abort 'Usage: ruby vglist.rb vglist-games.json wd-vglist-ids.tsv wd-video-games-no-vglist.tsv [out-dir]'
end
out_dir ||= '.'
chunk_size = Integer(ENV.fetch('CHUNK_SIZE', '20000'))

export = JSON.parse(File.read(vglist_path))
vglist_games = export.fetch('games')
puts "#{vglist_games.count} games in the vglist export (exported at #{export['exported_at']})."

games_with_wikidata = vglist_games.reject { |g| g['wikidata_id'].nil? }
puts "#{games_with_wikidata.count} of them have a Wikidata ID."

# vglist ID -> items it's already on, and items that already have one.
vglist_id_in_use = Hash.new { |h, k| h[k] = [] }
items_with_vglist_id = {}
read_sparql_tsv(vglist_ids_path).each do |row|
  qid = qid_from(row['item'])
  next if qid.nil?

  vglist_id_in_use[literal_from(row['vglist'])] << qid
  items_with_vglist_id[qid] = true
end
puts "#{vglist_id_in_use.count} vglist IDs are already on Wikidata, on #{items_with_vglist_id.count} items."

# QID -> label (nil when the item has no English or mul label).
candidate_labels = {}
read_sparql_tsv(candidates_path).each do |row|
  qid = qid_from(row['item'])
  next if qid.nil?

  label = literal_from(row['label'])
  candidate_labels[qid] = label.empty? ? nil : label
end
puts "#{candidate_labels.count} video games on Wikidata have no vglist ID."

games_per_qid = games_with_wikidata.group_by { |g| "Q#{g['wikidata_id']}" }

statements = []
mismatches = []
skipped = []

games_with_wikidata.each do |game|
  qid = "Q#{game['wikidata_id']}"
  vglist_id = game['id'].to_s

  reason =
    if items_with_vglist_id.key?(qid)
      'item already has a vglist ID'
    elsif !candidate_labels.key?(qid)
      'item not in the query result (not a video game, a redirect, or deleted)'
    elsif games_per_qid[qid].length > 1
      "item is linked from several vglist games: #{games_per_qid[qid].map { |g| g['id'] }.join(',')}"
    elsif vglist_id_in_use.key?(vglist_id)
      "vglist ID already used on #{vglist_id_in_use[vglist_id].join(',')}"
    end

  if reason
    # Don't clutter the file with the ones that are already done.
    skipped << [reason, qid, vglist_id, game['name']] unless vglist_id_in_use[vglist_id] == [qid]
    next
  end

  label = candidate_labels[qid]
  if label && games_have_same_name?(game['name'], label)
    statements << tsv_row([qid, 'P8351', "\"#{vglist_id}\""])
  else
    mismatches << [qid, vglist_id, game['name'], label.to_s]
  end
end

Dir.glob(File.join(out_dir, 'vglist-ids*.qs.tsv')).each { |f| File.delete(f) }
batch_files =
  if statements.length > chunk_size
    statements.each_slice(chunk_size).with_index(1).map do |slice, i|
      path = File.join(out_dir, format('vglist-ids.%03d.qs.tsv', i))
      File.write(path, slice.join("\n") + "\n")
      path
    end
  else
    path = File.join(out_dir, 'vglist-ids.qs.tsv')
    File.write(path, statements.map { |s| "#{s}\n" }.join)
    [path]
  end

File.write(
  File.join(out_dir, 'vglist-name-mismatches.tsv'),
  ([tsv_row(%w[qid vglist_id vglist_name wikidata_label])] + mismatches.map { |m| tsv_row(m) }).join("\n") + "\n"
)
File.write(
  File.join(out_dir, 'vglist-skipped.tsv'),
  ([tsv_row(%w[reason qid vglist_id vglist_name])] + skipped.map { |s| tsv_row(s) }).join("\n") + "\n"
)

puts "#{statements.count} statements written to #{batch_files.join(', ')}."
puts "#{mismatches.count} games match by Wikidata ID but have a different name, see vglist-name-mismatches.tsv."
puts "#{skipped.count} other games skipped, see vglist-skipped.tsv:"
skipped.map { |s| s.first.sub(/:.*|on Q.*/, '').strip }.tally.sort_by { |_, n| -n }.each do |r, n|
  puts "  #{n}  #{r}"
end
