# frozen_string_literal: true

##
# USAGE:
#
#   STEAM_API_KEY=... ruby steam_app_list_dump.rb
#
# Downloads Steam's full app list (every app ID and name) into
# data/steam_app_list.jsonl, which igdb_store_ids_quickstatements.rb uses to
# check Steam IDs against Steam's own names. See steam_app_list.rb.
#
# ENVIRONMENT VARIABLES:
#
# STEAM_API_KEY: a Steam Web API key, from
# https://steamcommunity.com/dev/apikey.

require_relative './steam_app_list.rb'

trap("SIGINT") { exit! }

SteamAppList.download
