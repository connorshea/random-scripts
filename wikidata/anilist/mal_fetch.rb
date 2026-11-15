# frozen_string_literal: true

##
# USAGE:
#
#   MAL_CLIENT_ID=... ruby mal_fetch.rb anime|manga [ids-file]
#
# Fetches the MyAnimeList titles of every MAL ID listed in ids-file (one per
# line) from MAL's official API into data/mal_<type>.jsonl. Get a client ID
# at https://myanimelist.net/apiconfig. See mal_titles.rb. IDs that are
# already cached are skipped, so it's safe to run again after an
# interruption.
#
# ids-file defaults to data/anilist-mal-<type>-mal-ids-to-check.txt, which
# anilist_mal_quickstatements.rb writes: the MAL IDs its candidates need
# checked. Run the generator again afterwards to use the titles.

require_relative './mal_titles.rb'

trap("SIGINT") { exit! }

type = ARGV[0].to_s.downcase
abort "Usage: ruby #{File.basename(__FILE__)} anime|manga [ids-file]" unless MALTitles::TYPES.include?(type)

ids_path = ARGV[1] || File.join(AniListAPI::DATA_DIR, "anilist-mal-#{type}-mal-ids-to-check.txt")
abort "No #{ids_path}. Run anilist_mal_quickstatements.rb #{type} first." unless File.exist?(ids_path)

ids = File.readlines(ids_path, chomp: true).map(&:strip).reject(&:empty?)
failed = MALTitles.fetch_missing(type, ids)
if failed.positive?
  abort "[#{AniListAPI.timestamp}] #{failed} MAL #{type} IDs couldn't be fetched. Run this again to retry them."
end
AniListAPI.log "Every MAL #{type} ID is cached in #{MALTitles.cache_path(type)}."
