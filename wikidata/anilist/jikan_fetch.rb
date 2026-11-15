# frozen_string_literal: true

##
# USAGE:
#
#   ruby jikan_fetch.rb anime|manga [ids-file]
#   MAL_CLIENT_ID=... ruby jikan_fetch.rb anime|manga [ids-file]
#
# Fetches the MyAnimeList titles of every MAL ID listed in ids-file (one per
# line) into data/mal_<type>.jsonl, from Jikan, an unofficial MAL API, or,
# when MAL_CLIENT_ID is set, from MAL's official API (get a client ID at
# https://myanimelist.net/apiconfig). See jikan_api.rb. IDs
# that are already cached are skipped, so it's safe to run again after an
# interruption.
#
# ids-file defaults to data/anilist-mal-<type>-mal-ids-to-check.txt, which
# anilist_mal_quickstatements.rb writes: the MAL IDs its candidates need
# checked. Run the generator again afterwards to use the titles.

require_relative './jikan_api.rb'

trap("SIGINT") { exit! }

type = ARGV[0].to_s.downcase
abort "Usage: ruby #{File.basename(__FILE__)} anime|manga [ids-file]" unless JikanAPI::TYPES.include?(type)

ids_path = ARGV[1] || File.join(AniListAPI::DATA_DIR, "anilist-mal-#{type}-mal-ids-to-check.txt")
abort "No #{ids_path}. Run anilist_mal_quickstatements.rb #{type} first." unless File.exist?(ids_path)

ids = File.readlines(ids_path, chomp: true).map(&:strip).reject(&:empty?)
failed = JikanAPI.fetch_missing(type, ids)
if failed.positive?
  abort "[#{AniListAPI.timestamp}] #{failed} MAL #{type} IDs couldn't be fetched. Run this again to retry them."
end
AniListAPI.log "Every MAL #{type} ID is cached in #{JikanAPI.cache_path(type)}."
