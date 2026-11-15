# frozen_string_literal: true

##
# USAGE:
#
#   ruby steam_release_fetch.rb ids-file
#
# Fetches Steam's release information (date, "coming soon", how precise the
# date is) for each app ID in ids-file (one per line) into
# data/steam_release.jsonl. Only app IDs that aren't cached yet are fetched,
# 100 per request. See steam_release.rb.
#
# ENVIRONMENT VARIABLES:
#
# STEAM_API_KEY: optional, a Steam Web API key. Sent if set.

require_relative './steam_release.rb'

trap("SIGINT") { exit! }

ids_path = ARGV[0]
abort "Usage: ruby #{File.basename(__FILE__)} ids-file" if ids_path.nil?
abort "#{ids_path} doesn't exist." unless File.exist?(ids_path)

SteamRelease.fetch_missing(File.readlines(ids_path, chomp: true).map(&:strip).reject(&:empty?))
