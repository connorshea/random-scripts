# frozen_string_literal: true

##
# USAGE:
#
#   ruby steam_platforms_fetch.rb [ids-file]
#
# Fetches the platforms Steam lists for each app ID in ids-file (one per
# line; default data/igdb-steam-ids-to-check.txt, written by
# igdb_store_ids_quickstatements.rb) into data/steam_platforms.jsonl. Only
# app IDs that aren't cached yet are fetched, 100 per request. See
# steam_platforms.rb.
#
# ENVIRONMENT VARIABLES:
#
# STEAM_API_KEY: optional, a Steam Web API key. Sent if set.

require_relative './steam_platforms.rb'

trap("SIGINT") { exit! }

ids_path = ARGV[0] || File.join(__dir__, 'data', 'igdb-steam-ids-to-check.txt')
abort "#{ids_path} doesn't exist. Run igdb_store_ids_quickstatements.rb first." unless File.exist?(ids_path)

SteamPlatforms.fetch_missing(File.readlines(ids_path, chomp: true).map(&:strip).reject(&:empty?))
