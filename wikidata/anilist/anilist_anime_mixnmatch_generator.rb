# frozen_string_literal: true

##
# USAGE:
#
# This script pulls down every anime from AniList and then generates a
# mix'n'match catalogue TSV.
#
# ENVIRONMENT VARIABLES:
#
# USE_ANILIST_API (optional): download a fresh copy of every anime from the AniList API first (or resume an interrupted download). Otherwise the existing dump in data/ is used, see anilist_dump.rb.

require_relative './anilist_api.rb'

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

ANILIST_ANIME_PID = 'P8729'

TSV_PATH = File.join(__dir__, 'anilist_anime_mixnmatch.tsv')

anilist_anime = AniListAPI.load('ANIME')

puts "#{anilist_anime.count} anime on AniList"

# Media formats and humanized names for them.
MEDIA_FORMAT_HASH = {
  'TV' => 'TV show',
  'TV_SHORT' => 'TV short',
  'MOVIE' => 'movie',
  'SPECIAL' => 'special episode',
  'OVA' => 'OVA',
  'ONA' => 'ONA',
  'MUSIC' => 'music video'
}.freeze

# Map of MEDIA_FORMATs from AniList to Wikidata item types.
WIKIDATA_ITEM_TYPE_MAP = {
  'TV' => 'Q63952888', # anime television series
  'TV_SHORT' => 'Q63952888', # anime television series
  'MOVIE' => 'Q20650540', # anime film
  'SPECIAL' => nil, # can be multiple different things
  'OVA' => 'Q220898', # original video animation
  'ONA' => 'Q1047299', # original net animation
  'MUSIC' => nil # hard to pin down what this should be.
}.freeze

File.open(TSV_PATH, 'w') do |file|
  anilist_anime.each_with_index do |anime, index|
    # Prefer the English title, then Romaji, then Native. Strip out tab
    # characters because apparently there are a few of them in titles on
    # AniList 🤨
    titles = anime['title']
    title = (titles['english'] || titles['romaji'] || titles['native']).to_s.delete("\t")

    format = anime['format']
    status = anime['status']
    studios = anime.dig('studios', 'nodes').map { |studio| studio['name'] }

    # Generate a description based on the data we have.
    description = +''
    # Unreleased or Cancelled, if relevant. Otherwise, ignore the status.
    description << 'Unreleased ' if status == 'NOT_YET_RELEASED'
    description << 'Cancelled ' if status == 'CANCELLED'
    # The release year, if we have one.
    description << "#{anime['seasonYear']} " unless anime['seasonYear'].nil?
    # The type of anime, e.g. television short.
    description << (MEDIA_FORMAT_HASH[format] || 'anime')
    # The first one or two studios involved, if any.
    description << " by #{studios.first(2).join(' and ')}" unless studios.empty?
    description << '.'

    # A Q-ID for the type of item this is, or a blank string if unknown.
    type = WIKIDATA_ITEM_TYPE_MAP[format] || ''

    file << "\n" unless index.zero?
    file << anime['id'].to_s << "\t" << title << "\t" << description << "\t" << type
  end
end
