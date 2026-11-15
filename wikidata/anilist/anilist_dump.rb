# frozen_string_literal: true

##
# USAGE:
#
#   ruby anilist_dump.rb anime
#   ruby anilist_dump.rb manga
#   ruby anilist_dump.rb anime manga
#
# Downloads every anime and/or manga from the AniList API into
# data/anilist_<type>.jsonl, which the other scripts in this directory read.
# If a download is interrupted, run the same command again to resume it.
#
# ENVIRONMENT VARIABLES:
#
# ANILIST_REQUEST_INTERVAL (optional): seconds between requests. By default
# requests are paced to the rate limit AniList reports.

require_relative './anilist_api.rb'

trap("SIGINT") { exit! }

types = ARGV.map(&:upcase)
if types.empty? || !types.all? { |type| AniListAPI::FIELDS.key?(type) }
  abort "Usage: ruby #{File.basename(__FILE__)} anime|manga [anime|manga]"
end

types.uniq.each { |type| AniListAPI.download(type) }
