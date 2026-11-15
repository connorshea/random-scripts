# frozen_string_literal: true

##
# Writes a QuickStatements batch that fills in missing AniList anime IDs
# (P8729) and MyAnimeList anime IDs (P4086) on Wikidata items that have one
# but not the other, using the MAL IDs in the AniList dump.
#
# Nothing is edited and no web service is called. The inputs are files:
#
# 1. The AniList anime dump, data/anilist_anime.jsonl (see anilist_dump.rb).
# 2. wd-anilist-mal-ids.tsv: the result of wd-anilist-mal-ids.rq (every P8729
#    and P4086 value on Wikidata and the item it's on), saved as TSV from
#    QLever or the Wikidata Query Service.
# 3. wd-anilist-mal-names.tsv: the result of wd-anilist-mal-names.rq (labels
#    and aliases of the items that have only one of the two IDs).
#
# USAGE:
#
#   ruby anilist_mal_quickstatements.rb wd-anilist-mal-ids.tsv wd-anilist-mal-names.tsv [out-dir]
#
# For an item with AniList ID(s) but no MAL ID, the MAL ID of its AniList
# entry is added. For an item with MAL ID(s) but no AniList ID, the AniList
# entry with that MAL ID is added. Either way, only when:
# - the AniList entry exists in the dump and (for the first case) has a MAL ID,
# - the item's IDs all point to the same single candidate,
# - the ID being added isn't already on another Wikidata item, and no other
#   item in this batch would get it too,
# - one of the item's labels or aliases matches one of the AniList entry's
#   English, romaji or native titles (see names_match?),
# - both IDs match the properties' format constraint, [1-9]\d*.
#
# Each statement gets a reference with the other ID it was derived from (the
# item's AniList anime ID for a new MAL ID, the item's MAL anime ID for a new
# AniList ID) and retrieved (P813) set to the date the AniList dump was
# downloaded.
#
# Writes to out-dir (default: data/):
# - anilist-mal-ids.qs.tsv: the QuickStatements batch, in the tab-separated
#   (v1) command syntax.
# - anilist-mal-name-mismatches.tsv: items that could be matched by ID but
#   whose names differ from the AniList titles, for manual review. Each row
#   includes the QuickStatements command, so approved rows can be copied over.
# - anilist-mal-skipped.tsv: every other candidate that wasn't added, and why.

require 'json'
require 'rubygems/text'
require_relative './anilist_api.rb'

ANILIST_ANIME_PID = 'P8729'
MAL_ANIME_PID = 'P4086'
RETRIEVED_PID = 'P813'

# Format constraint (P1793) of both P8729 and P4086: a positive integer with
# no leading zeros.
ID_FORMAT = /\A[1-9]\d*\z/

LEVENSHTEIN = Class.new.extend(Gem::Text).method(:levenshtein_distance)

# Lowercase, NFKC-normalize (full-width -> ASCII etc.) and drop everything
# that isn't a letter or digit, so "Aikatsu!" and "aikatsu" compare equal.
def normalize_name(name)
  name.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^\p{L}\p{N}]+/, '')
end

# Wikidata often labels the first season of a show "X, season 1" or
# "X 第1期" when AniList just calls it "X", so these are ignored when
# comparing names.
FIRST_SEASON_MARKERS = [
  /,?\s*season\s*(?:1|one)\b/i,
  /\s*\b(?:1st|first)\s+season\b/i,
  /\s*第\s*[1一]\s*(?:期|季|章|シーズン)/
].freeze

def without_first_season_marker(name)
  FIRST_SEASON_MARKERS.reduce(name.to_s) { |n, marker| n.gsub(marker, '') }
end

# True if any Wikidata label/alias matches any AniList title, exactly after
# normalizing (and ignoring "season 1" markers on the Wikidata side), or
# within a Levenshtein distance of 2 for longer names.
def names_match?(wikidata_names, anilist_titles)
  wikidata_names = wikidata_names.flat_map { |n| [n, without_first_season_marker(n)] }
  wd = wikidata_names.map { |n| normalize_name(n) }.reject(&:empty?).uniq
  al = anilist_titles.map { |n| normalize_name(n) }.reject(&:empty?).uniq
  return true if wd.intersect?(al)

  wd.product(al).any? do |a, b|
    [a.length, b.length].min >= 8 && (a.length - b.length).abs <= 2 && LEVENSHTEIN.call(a, b) <= 2
  end
end

# Reads a SPARQL TSV result (QLever or WDQS) into an array of hashes keyed by
# variable name without the "?".
def read_sparql_tsv(path)
  lines = File.readlines(path, chomp: true)
  abort "#{path} doesn't look like a SPARQL TSV result:\n#{lines.first(5).join("\n")}" unless lines.first&.start_with?('?')

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

ids_path, names_path, out_dir = ARGV
abort 'Usage: ruby anilist_mal_quickstatements.rb wd-anilist-mal-ids.tsv wd-anilist-mal-names.tsv [out-dir]' if ids_path.nil? || names_path.nil?
out_dir ||= AniListAPI::DATA_DIR

# --- AniList dump ---
anilist = AniListAPI.load('ANIME', download: false)
anilist_by_id = anilist.to_h { |media| [media['id'].to_s, media] }
anilist_by_mal_id = anilist.reject { |media| media['idMal'].nil? }.group_by { |media| media['idMal'].to_s }
# QuickStatements time value, day precision.
retrieved = File.mtime(AniListAPI.dump_path('ANIME')).utc.strftime('+%Y-%m-%dT00:00:00Z/11')
puts "#{anilist.count} anime in the AniList dump, #{anilist_by_mal_id.count} distinct MAL IDs."

# --- Wikidata IDs ---
anilist_ids_by_item = Hash.new { |h, k| h[k] = [] }
mal_ids_by_item = Hash.new { |h, k| h[k] = [] }
items_by_anilist_id = Hash.new { |h, k| h[k] = [] }
items_by_mal_id = Hash.new { |h, k| h[k] = [] }
read_sparql_tsv(ids_path).each do |row|
  qid = qid_from(row['item'])
  next if qid.nil?

  anilist_id = literal_from(row['anilist'])
  mal_id = literal_from(row['mal'])
  unless anilist_id.empty?
    anilist_ids_by_item[qid] |= [anilist_id]
    items_by_anilist_id[anilist_id] |= [qid]
  end
  unless mal_id.empty?
    mal_ids_by_item[qid] |= [mal_id]
    items_by_mal_id[mal_id] |= [qid]
  end
end
puts "Wikidata: #{anilist_ids_by_item.count} items with an AniList anime ID, #{mal_ids_by_item.count} with a MAL anime ID."

names_by_item = Hash.new { |h, k| h[k] = [] }
read_sparql_tsv(names_path).each do |row|
  qid = qid_from(row['item'])
  names_by_item[qid] |= [literal_from(row['name'])] unless qid.nil?
end

# --- Candidates ---
# Each candidate: [qid, property to add, value, AniList entry]
candidates = []
skipped = []

(anilist_ids_by_item.keys - mal_ids_by_item.keys).sort_by { |q| q[1..].to_i }.each do |qid|
  anilist_ids = anilist_ids_by_item[qid]
  entries = anilist_ids.map { |id| anilist_by_id[id] }
  if entries.any?(&:nil?)
    missing = anilist_ids.reject { |id| anilist_by_id.key?(id) }
    skipped << [qid, MAL_ANIME_PID, '', "AniList ID #{missing.join(',')} not in the anime dump (deleted, merged, or a manga ID?)"]
    next
  end

  mal_ids = entries.map { |e| e['idMal'] }.compact.map(&:to_s).uniq
  if mal_ids.empty?
    skipped << [qid, MAL_ANIME_PID, '', "AniList #{anilist_ids.join(',')} has no MAL ID"]
  elsif mal_ids.length > 1
    skipped << [qid, MAL_ANIME_PID, mal_ids.join(','), "item's AniList IDs point to different MAL IDs"]
  else
    entry = entries.find { |e| e['idMal'].to_s == mal_ids.first }
    candidates << [qid, MAL_ANIME_PID, mal_ids.first, entry]
  end
end

(mal_ids_by_item.keys - anilist_ids_by_item.keys).sort_by { |q| q[1..].to_i }.each do |qid|
  entries = mal_ids_by_item[qid].flat_map { |mal_id| anilist_by_mal_id.fetch(mal_id, []) }.uniq { |e| e['id'] }
  if entries.empty?
    skipped << [qid, ANILIST_ANIME_PID, '', "no AniList anime with MAL ID #{mal_ids_by_item[qid].join(',')}"]
  elsif entries.length > 1
    skipped << [qid, ANILIST_ANIME_PID, entries.map { |e| e['id'] }.join(','), "several AniList anime have MAL ID #{mal_ids_by_item[qid].join(',')}"]
  else
    candidates << [qid, ANILIST_ANIME_PID, entries.first['id'].to_s, entries.first]
  end
end

# --- Filter candidates ---
statements = []
mismatches = []
value_counts = candidates.map { |_, pid, value, _| [pid, value] }.tally

candidates.each do |qid, pid, value, entry|
  in_use = (pid == MAL_ANIME_PID ? items_by_mal_id : items_by_anilist_id)[value]
  titles = entry['title'].values_at('english', 'romaji', 'native').compact

  # Reference the other ID the value was derived from: a MAL ID comes from
  # the item's AniList entry, an AniList ID was found via the item's MAL ID.
  source_pid, source_value =
    if pid == MAL_ANIME_PID
      [ANILIST_ANIME_PID, entry['id'].to_s]
    else
      [MAL_ANIME_PID, entry['idMal'].to_s]
    end
  command = tsv_row([
    qid, pid, "\"#{value}\"",
    source_pid.sub('P', 'S'), "\"#{source_value}\"",
    RETRIEVED_PID.sub('P', 'S'), retrieved
  ])

  if !value.match?(ID_FORMAT)
    skipped << [qid, pid, value, "#{pid} value doesn't match the format constraint [1-9]\d*"]
  elsif !source_value.match?(ID_FORMAT)
    skipped << [qid, pid, value, "reference #{source_pid} value #{source_value.inspect} doesn't match the format constraint [1-9]\d*"]
  elsif in_use.any?
    skipped << [qid, pid, value, "already used on #{in_use.join(',')}"]
  elsif value_counts[[pid, value]] > 1
    others = candidates.select { |_, p, v, _| p == pid && v == value }.map(&:first) - [qid]
    skipped << [qid, pid, value, "would also be added to #{others.join(',')}"]
  elsif names_match?(names_by_item[qid], titles)
    statements << command
  else
    mismatches << [qid, pid, value, entry['id'], titles.join(' / '), names_by_item[qid].first(8).join(' / '), command]
  end
end

# --- Write ---
qs_path = File.join(out_dir, 'anilist-mal-ids.qs.tsv')
File.write(qs_path, statements.map { |s| "#{s}\n" }.join)
File.write(
  File.join(out_dir, 'anilist-mal-name-mismatches.tsv'),
  ([tsv_row(%w[qid property value anilist_id anilist_titles wikidata_names quickstatements])] + mismatches.map { |m| tsv_row(m) }).join("\n") + "\n"
)
File.write(
  File.join(out_dir, 'anilist-mal-skipped.tsv'),
  ([tsv_row(%w[qid property value reason])] + skipped.map { |s| tsv_row(s) }).join("\n") + "\n"
)

adds = statements.map { |s| s.split("\t")[1] }.tally
puts "#{statements.count} statements written to #{qs_path} " \
     "(#{adds[MAL_ANIME_PID].to_i} MAL IDs, #{adds[ANILIST_ANIME_PID].to_i} AniList IDs)."
puts "#{mismatches.count} name mismatches to review in #{File.join(out_dir, 'anilist-mal-name-mismatches.tsv')}."
puts "#{skipped.count} skipped, see #{File.join(out_dir, 'anilist-mal-skipped.tsv')}."
