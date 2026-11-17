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
# Steam IDs get a platform (P400) qualifier for each platform Steam lists
# (Windows, macOS, Linux), from data/steam_platforms.jsonl, fetched with
# steam_platforms_fetch.rb for the app IDs this script writes to
# igdb-steam-ids-to-check.txt. Items also get distributed by (P750) Steam
# (Q337535), unless they already have it. Likewise, items getting an Epic or
# GOG ID get P750 Epic Games Store (Q59510068) or GOG.com (Q1486288). P750
# never gets platform qualifiers, and its reference is just inferred from
# (P3452) the store. Each ID property's constraints require that P750
# statement. Steam candidates whose platforms haven't been fetched are
# skipped.
#
# Items that already have the Steam ID IGDB links to, but no platform
# qualifier on it or no P750 Steam (for example from an earlier, partly run
# batch), get those added by igdb-steam-qualifiers.qs.tsv.
#
# Each new ID statement gets a reference: stated in (P248) IGDB (Q20056333), the
# IGDB game ID it came from, and retrieved (P813) set to the date the IGDB
# dump was downloaded.
#
# Writes to out-dir (default: data/):
# - igdb-steam-ids.qs.tsv, igdb-epic-ids.qs.tsv, igdb-gog-ids.qs.tsv: the
#   QuickStatements batches, in the tab-separated (v1) command syntax.
# - igdb-steam-qualifiers.qs.tsv: platform qualifiers and P750 Steam for
#   items that already have the Steam ID.
# - igdb-steam-ids-to-check.txt: Steam app IDs whose platforms haven't been
#   fetched, for steam_platforms_fetch.rb.
# - igdb-store-ids-name-mismatches.tsv: candidates whose names or store
#   slugs don't match, or that Steam's app list disagrees with, for manual
#   review. Each row includes the QuickStatements commands (several are
#   joined with "||", which QuickStatements reads as a line break), so
#   approved rows can be copied over.
# - igdb-store-ids-skipped.tsv: every other candidate that wasn't added, and
#   why.

require 'json'
require_relative './game_names.rb'
require_relative './steam_app_list.rb'
require_relative './steam_platforms.rb'
require_relative './sparql_tsv.rb'

IGDB_PID = 'P5794'
STATED_IN_PID = 'P248'
RETRIEVED_PID = 'P813'
IGDB_QID = 'Q20056333'
PLATFORM_PID = 'P400'
DISTRIBUTED_BY_PID = 'P750'
INFERRED_FROM_PID = 'P3452'

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
    # distributed by (P750), which the property's constraints require.
    distributor: 'Q337535', # Steam
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
    distributor: 'Q59510068', # Epic Games Store
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
    distributor: 'Q1486288', # GOG.com
    # https://www.gog.com/en/game/thief_3 -> "game/thief_3"
    from_url: lambda { |url|
      slug = url[%r{\Ahttps?://(?:www\.)?gog\.com/(?:[a-z]{2}/)?game/([^/?#]+)}i, 1]
      "game/#{slug}" unless slug.nil?
    },
    # Format constraint: ^(movie|game)/[a-z\d]+([\_]{1,2}[a-z\d]+){0,10}$
    format: %r{\A(?:movie|game)/[a-z\d]++(?:_{1,2}[a-z\d]++){0,10}+\z}
  }
}.freeze

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

# The QuickStatements reference for a statement from an IGDB game.
def igdb_reference(slug, retrieved)
  [STATED_IN_PID.sub('P', 'S'), IGDB_QID, IGDB_PID.sub('P', 'S'), "\"#{slug}\"", RETRIEVED_PID.sub('P', 'S'), retrieved]
end

# distributed by (P750) the store, referenced with inferred from (P3452) the
# store rather than IGDB.
def distributor_command(qid, distributor_qid)
  [qid, DISTRIBUTED_BY_PID, distributor_qid, INFERRED_FROM_PID.sub('P', 'S'), distributor_qid]
end

def platform_qualifiers(platform_qids)
  platform_qids.flat_map { |q| [PLATFORM_PID, q] }
end

# QuickStatements commands for a Steam ID with the platform qualifiers and,
# unless the item has it, P750 Steam (without qualifiers).
def steam_commands(qid, value, platform_qids, reference, has_distributor:)
  qualifiers = platform_qualifiers(platform_qids)
  commands = [tsv_row([qid, STORES['steam'][:pid], "\"#{value}\"", *qualifiers, *reference])]
  commands << tsv_row(distributor_command(qid, STORES['steam'][:distributor])) unless has_distributor
  commands
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
# Item => Steam IDs whose statement has a platform qualifier.
steam_ids_with_platform_by_item = Hash.new { |h, k| h[k] = [] }
# Item => its distributed by (P750) values that are one of the stores.
distributors_by_item = Hash.new { |h, k| h[k] = [] }
store_ids_by_item = STORES.keys.to_h { |key| [key, Hash.new { |h, k| h[k] = [] }] }
items_by_store_id = STORES.keys.to_h { |key| [key, Hash.new { |h, k| h[k] = [] }] }
id_rows = read_sparql_tsv(ids_path)
unless id_rows.first&.key?('distributor')
  abort "#{ids_path} has no distributor column. It's from an older version of wd-igdb-store-ids.rq; run the query again."
end
id_rows.each do |row|
  qid = qid_from(row['item'])
  next if qid.nil?

  with_platform = literal_from(row['steam_with_platform'])
  steam_ids_with_platform_by_item[qid] |= [with_platform] unless with_platform.empty?
  distributor = qid_from(literal_from(row['distributor']))
  distributors_by_item[qid] |= [distributor] unless distributor.nil?

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
steam_platforms = SteamPlatforms.load
puts "Platforms fetched for #{steam_platforms.count} Steam apps."
steam_ids_to_check = []

# --- Candidates ---
statements = STORES.keys.to_h { |key| [key, []] }
mismatches = []
skipped = []
steam_fixes = []

STORES.each do |key, store|
  pid = store[:pid]
  candidates = []

  igdb_slugs_by_item.keys.sort_by { |q| q[1..].to_i }.each do |qid|
    slugs = igdb_slugs_by_item[qid]
    games = slugs.map { |slug| igdb_by_slug[slug] }

    if store_ids_by_item[key].key?(qid)
      # The item has a Steam ID already. If it's the one IGDB links to, add
      # what it's missing: platform qualifiers and P750 Steam.
      existing = store_ids_by_item[key][qid]
      next unless key == 'steam' && existing.length == 1 && games.none?(&:nil?)
      next unless games.flat_map { |g| g[key] }.uniq == existing

      value = existing.first
      needs_platforms = !steam_ids_with_platform_by_item[qid].include?(value)
      needs_distributor = !distributors_by_item[qid].include?(store[:distributor])
      next unless needs_platforms || needs_distributor

      unless steam_platforms.key?(value)
        steam_ids_to_check << value
        skipped << [key, qid, pid, value, 'has this Steam ID; platforms not fetched yet, run steam_platforms_fetch.rb']
        next
      end
      platform_qids = steam_platforms[value]
      if platform_qids.nil? || platform_qids.empty?
        skipped << [key, qid, pid, value, "has this Steam ID; Steam #{platform_qids.nil? ? "didn't return the app" : 'lists no platforms'}"]
        next
      end

      game = games.find { |g| g[key].include?(value) }
      # The Steam ID statement exists, so this only adds qualifiers to it.
      steam_fixes << tsv_row([qid, pid, "\"#{value}\"", *platform_qualifiers(platform_qids)]) if needs_platforms
      steam_fixes << tsv_row(distributor_command(qid, STORES['steam'][:distributor])) if needs_distributor
      next
    end
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
    reference = igdb_reference(game['slug'], retrieved)
    commands = [tsv_row([qid, pid, "\"#{value}\"", *reference])]
    unless distributors_by_item[qid].include?(store[:distributor])
      commands << tsv_row(distributor_command(qid, store[:distributor]))
    end
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

        unless steam_platforms.key?(value)
          steam_ids_to_check << value
          skipped << [key, qid, pid, value, 'platforms not fetched yet, run steam_platforms_fetch.rb']
          next
        end
        platform_qids = steam_platforms[value]
        if platform_qids.nil?
          reasons << "Steam didn't return the app's platforms"
        elsif platform_qids.empty?
          reasons << 'Steam lists no platforms'
        end
        commands = steam_commands(qid, value, platform_qids || [], reference, has_distributor: distributors_by_item[qid].include?(store[:distributor]))
      end

      if reasons.empty?
        statements[key].concat(commands)
      else
        mismatches << [key, qid, pid, value, reasons.join('; '), game['slug'], game['name'], names_by_item[qid].first(8).join(' / '), commands.map { |c| c.tr("\t", '|') }.join('||')]
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
fixes_path = File.join(out_dir, 'igdb-steam-qualifiers.qs.tsv')
File.write(fixes_path, steam_fixes.map { |s| "#{s}\n" }.join)
puts "#{steam_fixes.count} platform qualifier and P750 Steam commands for items that already have the Steam ID written to #{fixes_path}."
to_check_path = File.join(out_dir, 'igdb-steam-ids-to-check.txt')
File.write(to_check_path, steam_ids_to_check.uniq.map { |id| "#{id}\n" }.join)
if steam_ids_to_check.any?
  puts "#{steam_ids_to_check.uniq.count} Steam apps need their platforms fetched: run `ruby steam_platforms_fetch.rb`, then this again."
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
