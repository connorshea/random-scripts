# frozen_string_literal: true

##
# Writes QuickStatements batches that add Steam application IDs (P1733), Epic
# Games Store IDs (P6278) and GOG application IDs (P2725) to Wikidata items
# with an IGDB game ID (P5794), using the store links in the IGDB dump.
#
# Nothing is edited and no web service is called. The inputs are files:
#
# 1. The IGDB dump, igdb_games.json (see igdb_dumper.rb).
# 2. wd-igdb-store-ids.tsv: the result of wd-igdb-store-ids.rq (every
#    non-deprecated IGDB ID, and every Steam, Epic and GOG ID, with the item
#    it's on), saved as TSV from QLever or the Wikidata Query Service.
# 3. wd-igdb-names.tsv: the result of wd-igdb-names.rq (en and mul labels
#    and aliases of every item with an IGDB ID).
#
# USAGE:
#
#   ruby igdb_store_ids_quickstatements.rb data/wd-igdb-store-ids.tsv data/wd-igdb-names.tsv [out-dir]
#
# For each store, an item gets that store's ID only when:
# - the item has no ID for that store yet (of any rank),
# - every IGDB ID on the item is in the dump, and together they link to
#   exactly one ID for that store,
# - no other IGDB game in the dump links to that store ID (which would mean
#   it's shared by editions, bundles or DLC),
# - the store ID isn't already on another item, and no other item in the
#   batch would get it too,
# - the ID matches the property's format constraint,
# - one of the item's en/mul labels or aliases matches the IGDB game's name
#   (see names_match?),
# - for Epic and GOG, the store's slug resembles the IGDB game's slug or name
#   (see store_slug_similar?), which catches links to bundles,
# - for Steam, the app ID is in Steam's app list and its name there matches
#   the IGDB name or one of the item's names. This also catches links to an
#   app's soundtrack, demo or DLC, whose names differ.
#
# Steam names come from data/steam_app_list.jsonl, Steam's full app list,
# downloaded with steam_app_list_dump.rb. Without it, no Steam statements are
# written.
#
# Each statement gets a reference: stated in (P248) IGDB (Q20056333), the
# IGDB game ID it came from, and retrieved (P813) set to the date the IGDB
# dump was downloaded.
#
# Writes to out-dir (default: data/):
# - igdb-steam-ids.qs.tsv, igdb-epic-ids.qs.tsv, igdb-gog-ids.qs.tsv: the
#   QuickStatements batches, in the tab-separated (v1) command syntax.
# - igdb-store-ids-name-mismatches.tsv: candidates whose names or store
#   slugs don't match, or that Steam's app list disagrees with, for manual
#   review. Each row includes the QuickStatements command, so
#   approved rows can be copied over.
# - igdb-store-ids-skipped.tsv: every other candidate that wasn't added, and
#   why.

require 'json'
require 'rubygems/text'
require_relative './steam_app_list.rb'

IGDB_PID = 'P5794'
STATED_IN_PID = 'P248'
RETRIEVED_PID = 'P813'
IGDB_QID = 'Q20056333'

# IGDB external_games.external_game_source and websites.type values (both
# copied into `category` by igdb_dumper.rb).
EXTERNAL_STEAM = 1
EXTERNAL_GOG = 5
EXTERNAL_EPIC = 26
WEBSITE_STEAM = 13
WEBSITE_EPIC = 16
WEBSITE_GOG = 17

STORES = {
  'steam' => {
    pid: 'P1733',
    column: 'steam',
    external: EXTERNAL_STEAM,
    website: WEBSITE_STEAM,
    # https://store.steampowered.com/app/211740/Thief/
    from_url: ->(url) { url[%r{\Ahttps?://store\.steampowered\.com/app/(\d+)}i, 1] },
    # Format constraint: [1-9]\d{0,6}
    format: /\A[1-9]\d{0,6}\z/
  },
  'epic' => {
    pid: 'P6278',
    column: 'epic',
    external: EXTERNAL_EPIC,
    website: WEBSITE_EPIC,
    # https://store.epicgames.com/en-US/p/thief-5bb95f,
    # https://www.epicgames.com/store/p/fallout-2
    from_url: ->(url) { url[%r{\Ahttps?://(?:store|www)\.epicgames\.com/(?:[a-z]{2}(?:-[a-z]{2})?/)?(?:store/)?(?:[a-z]{2}(?:-[a-z]{2})?/)?p/([^/?#]+)}i, 1] },
    # Format constraint: ^[a-z\d]+([\-]{0,3}[\_]?[^\sA-Z\W\_]+)*$, where
    # [^\sA-Z\W\_] is [a-z\d]. Possessive so a long non-match can't backtrack.
    format: /\A[a-z\d]++(?:-{0,3}_?[a-z\d]++)*+\z/
  },
  'gog' => {
    pid: 'P2725',
    column: 'gog',
    external: EXTERNAL_GOG,
    website: WEBSITE_GOG,
    # https://www.gog.com/en/game/thief_3 -> "game/thief_3"
    from_url: lambda { |url|
      slug = url[%r{\Ahttps?://(?:www\.)?gog\.com/(?:[a-z]{2}/)?game/([^/?#]+)}i, 1]
      "game/#{slug}" unless slug.nil?
    },
    # Format constraint: ^(movie|game)/[a-z\d]+([\_]{1,2}[a-z\d]+){0,10}$
    format: %r{\A(?:movie|game)/[a-z\d]++(?:_{1,2}[a-z\d]++){0,10}+\z}
  }
}.freeze

LEVENSHTEIN = Class.new.extend(Gem::Text).method(:levenshtein_distance)

# Lowercase, NFKC-normalize, drop trademark signs and a trailing
# "(video game)", treat "&" as "and", then drop everything that isn't a
# letter or digit.
def normalize_name(name)
  # Trademark signs go first, NFKC would turn ™ into "TM".
  name.to_s.gsub(/[™®©]/, '').unicode_normalize(:nfkc).downcase
      .sub(/\s*\((?:\d{4} )?video game\)\z/, '')
      .gsub('&', ' and ')
      .gsub(/[^\p{L}\p{N}]+/, '')
end

# True if any Wikidata name matches the IGDB name, exactly after normalizing,
# or within a Levenshtein distance of 2 for names of 8 or more characters.
def names_match?(wikidata_names, igdb_name)
  wd = wikidata_names.map { |n| normalize_name(n) }.reject(&:empty?).uniq
  igdb = normalize_name(igdb_name)
  return false if igdb.empty?
  return true if wd.include?(igdb)

  wd.any? do |name|
    [name.length, igdb.length].min >= 8 && (name.length - igdb.length).abs <= 2 && LEVENSHTEIN.call(name, igdb) <= 2
  end
end

# Epic and GOG IDs are slugs. IGDB sometimes links a game to a bundle or an
# unrelated product ("cossacks_ii_anthology" for Cossacks II), so a slug that
# doesn't resemble the IGDB game's slug or name is sent for review. Steam IDs
# are numbers, so they're always considered similar.
def store_slug_similar?(value, igdb_slug, igdb_name)
  return true if value.match?(/\A\d+\z/)

  slug = value.delete_prefix('game/').sub(/-[0-9a-f]{6}\z/, '').gsub(/[^a-z\d]/, '')
  igdb = [igdb_slug.sub(/--\d+\z/, '').gsub(/[^a-z\d]/, ''), normalize_name(igdb_name)].reject(&:empty?)
  return false if slug.empty?

  igdb.any? { |name| name.include?(slug) || slug.include?(name) || LEVENSHTEIN.call(name, slug) <= 2 }
end

# Reads a SPARQL TSV result (QLever or WDQS) into an array of hashes keyed by
# variable name without the "?".
def read_sparql_tsv(path)
  lines = File.readlines(path, chomp: true)
  abort "#{path} doesn't look like a SPARQL TSV result:\n#{lines.first(5).join("\n")}" unless lines.first&.start_with?('?')

  # QLever reports an error during export by appending it to the truncated
  # result, since the HTTP status has already been sent.
  if (error_line = lines.find { |l| l.include?('An error has occurred while exporting the query result') })
    abort "#{path} is truncated, the query failed partway through:\n#{error_line}"
  end

  header = lines.shift.split("\t").map { |h| h.delete_prefix('?') }
  lines.reject(&:empty?).map { |line| header.zip(line.split("\t", -1)).to_h }
end

# "<http://www.wikidata.org/entity/Q123>" -> "Q123"
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

# @return [Array<String>] every distinct ID for a store that an IGDB game
#   links to, from its external games and its websites.
def store_ids(game, store)
  ids = []
  game['external_games'].each do |ext|
    next unless ext['category'] == store[:external]

    # Steam's uid is the app ID; for Epic and GOG it's an internal ID, so
    # those come from the URL.
    ids << ext['uid'].to_s if store[:external] == EXTERNAL_STEAM && ext['uid'].to_s.match?(/\A\d+\z/)
    ids << store[:from_url].call(ext['url'].to_s)
  end
  game['websites'].each do |site|
    ids << store[:from_url].call(site['url'].to_s) if site['category'] == store[:website]
  end
  ids.compact.uniq
end

ids_path, names_path, out_dir = ARGV
abort "Usage: ruby #{File.basename(__FILE__)} wd-igdb-store-ids.tsv wd-igdb-names.tsv [out-dir]" if ids_path.nil? || names_path.nil?
out_dir ||= File.join(__dir__, 'data')
dump_path = File.join(__dir__, 'igdb_games.json')

# --- IGDB dump ---
puts "Reading #{dump_path} (downloaded #{File.mtime(dump_path).strftime('%Y-%m-%d %H:%M')})."
igdb_by_slug = {}
# For each store: store ID => slugs of every IGDB game that links to it.
igdb_slugs_by_store_id = STORES.keys.to_h { |key| [key, Hash.new { |h, k| h[k] = [] }] }
JSON.parse(File.read(dump_path)).each do |game|
  game['external_games'] ||= []
  game['websites'] ||= []
  entry = { 'name' => game['name'], 'slug' => game['slug'] }
  STORES.each do |key, store|
    entry[key] = store_ids(game, store)
    entry[key].each { |id| igdb_slugs_by_store_id[key][id] << game['slug'] }
  end
  igdb_by_slug[game['slug']] = entry
end
# QuickStatements time value, day precision.
retrieved = File.mtime(dump_path).utc.strftime('+%Y-%m-%dT00:00:00Z/11')
puts "#{igdb_by_slug.count} games in the IGDB dump."
STORES.each_key { |key| puts "  #{igdb_slugs_by_store_id[key].count} distinct #{key} IDs linked." }

# --- Wikidata ---
igdb_slugs_by_item = Hash.new { |h, k| h[k] = [] }
store_ids_by_item = STORES.keys.to_h { |key| [key, Hash.new { |h, k| h[k] = [] }] }
items_by_store_id = STORES.keys.to_h { |key| [key, Hash.new { |h, k| h[k] = [] }] }
read_sparql_tsv(ids_path).each do |row|
  qid = qid_from(row['item'])
  next if qid.nil?

  igdb = literal_from(row['igdb'])
  igdb_slugs_by_item[qid] |= [igdb] unless igdb.empty?
  STORES.each do |key, store|
    value = literal_from(row[store[:column]])
    next if value.empty?

    store_ids_by_item[key][qid] |= [value]
    items_by_store_id[key][value] |= [qid]
  end
end
puts "Wikidata: #{igdb_slugs_by_item.count} items with an IGDB ID."

names_by_item = Hash.new { |h, k| h[k] = [] }
read_sparql_tsv(names_path).each do |row|
  qid = qid_from(row['item'])
  names_by_item[qid] |= [literal_from(row['name'])] unless qid.nil?
end

steam_names = SteamAppList.load
if steam_names.nil?
  puts "No Steam app list at #{SteamAppList::PATH}, so no Steam statements will be written. " \
       "Download it with `ruby #{File.join(__dir__, 'steam_app_list_dump.rb')}`."
else
  puts "#{steam_names.count} apps in the Steam app list (downloaded #{File.mtime(SteamAppList::PATH).strftime('%Y-%m-%d %H:%M')})."
end

# --- Candidates ---
statements = STORES.keys.to_h { |key| [key, []] }
mismatches = []
skipped = []

STORES.each do |key, store|
  pid = store[:pid]
  candidates = []

  igdb_slugs_by_item.keys.sort_by { |q| q[1..].to_i }.each do |qid|
    next if store_ids_by_item[key].key?(qid)

    slugs = igdb_slugs_by_item[qid]
    games = slugs.map { |slug| igdb_by_slug[slug] }
    if games.any?(&:nil?)
      missing = slugs.reject { |slug| igdb_by_slug.key?(slug) }
      # Only worth reporting if another of the item's IGDB IDs has a link.
      skipped << [key, qid, pid, '', "IGDB ID #{missing.join(',')} not in the dump"] if games.compact.any? { |g| g[key].any? }
      next
    end

    values = games.flat_map { |g| g[key] }.uniq
    next if values.empty?

    if values.length > 1
      skipped << [key, qid, pid, values.join(','), "IGDB #{slugs.join(',')} links to several #{key} IDs"]
      next
    end

    value = values.first
    game = games.find { |g| g[key].include?(value) }
    candidates << [qid, value, game]
  end

  value_counts = candidates.map { |_, value, _| value }.tally
  candidates.each do |qid, value, game|
    command = tsv_row([
      qid, pid, "\"#{value}\"",
      STATED_IN_PID.sub('P', 'S'), IGDB_QID,
      IGDB_PID.sub('P', 'S'), "\"#{game['slug']}\"",
      RETRIEVED_PID.sub('P', 'S'), retrieved
    ])
    linked_from = igdb_slugs_by_store_id[key][value]
    in_use = items_by_store_id[key][value]

    if !value.match?(store[:format])
      skipped << [key, qid, pid, value, "doesn't match the #{pid} format constraint"]
    elsif linked_from.length > 1
      skipped << [key, qid, pid, value, "linked from several IGDB games: #{linked_from.first(5).join(',')}"]
    elsif in_use.any?
      skipped << [key, qid, pid, value, "already used on #{in_use.join(',')}"]
    elsif value_counts[value] > 1
      others = candidates.select { |_, v, _| v == value }.map(&:first) - [qid]
      skipped << [key, qid, pid, value, "would also be added to #{others.join(',')}"]
    else
      reasons = []
      reasons << "Wikidata names don't match IGDB" unless names_match?(names_by_item[qid], game['name'])
      reasons << "#{key} slug doesn't resemble the IGDB game" unless store_slug_similar?(value, game['slug'], game['name'])

      if key == 'steam'
        if steam_names.nil?
          skipped << [key, qid, pid, value, 'not checked against the Steam app list, run steam_app_list_dump.rb']
          next
        elsif !steam_names.key?(value)
          reasons << 'not in the Steam app list (removed, or not a game, DLC or software?)'
        elsif !names_match?(names_by_item[qid] + [game['name']], steam_names[value])
          reasons << "Steam name #{steam_names[value].inspect} doesn't match"
        end
      end

      if reasons.empty?
        statements[key] << command
      else
        mismatches << [key, qid, pid, value, reasons.join('; '), game['slug'], game['name'], names_by_item[qid].first(8).join(' / '), command]
      end
    end
  end
end

# --- Write ---
STORES.each_key do |key|
  path = File.join(out_dir, "igdb-#{key}-ids.qs.tsv")
  File.write(path, statements[key].map { |s| "#{s}\n" }.join)
  puts "#{statements[key].count} #{key} statements written to #{path}."
end
mismatches_path = File.join(out_dir, 'igdb-store-ids-name-mismatches.tsv')
skipped_path = File.join(out_dir, 'igdb-store-ids-skipped.tsv')
File.write(
  mismatches_path,
  ([tsv_row(%w[store qid property value reason igdb_slug igdb_name wikidata_names quickstatements])] + mismatches.map { |m| tsv_row(m) }).join("\n") + "\n"
)
File.write(
  skipped_path,
  ([tsv_row(%w[store qid property value reason])] + skipped.map { |s| tsv_row(s) }).join("\n") + "\n"
)
puts "#{mismatches.count} name mismatches to review in #{mismatches_path}."
puts "#{skipped.count} skipped, see #{skipped_path}."
