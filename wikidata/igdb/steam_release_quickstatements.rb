# frozen_string_literal: true

##
# Writes a QuickStatements batch that adds publication date (P577) statements
# from Steam's release dates, for items that have no publication date.
#
# Nothing is edited and no web service is called. The inputs are files:
#
# 1. items-file: a TSV of items with no P577 statement, with the item's QID
#    in the first column and its Steam app ID in the second, e.g.
#    data/edited-steam-no-date.tsv.
# 2. data/steam_release.jsonl: Steam's release information for those apps,
#    fetched with steam_release_fetch.rb.
#
# USAGE:
#
#   ruby steam_release_quickstatements.rb items-file [out-file]
#
# Only apps Steam lists as released (not "coming soon") get a statement, with
# day precision. Apps in early access get the qualifier object of statement
# has role (P3831) early access (Q17042291). Each statement is referenced with
# stated in (P248) Steam (Q337535), the Steam app ID, and retrieved (P813),
# the date the release information was fetched:
#
#   Q123	P577	+2018-07-09T00:00:00Z/11	S248	Q337535	S1733	"866180"	S813	+2026-11-15T00:00:00Z/11
#
# Writes out-file (default: data/steam-release-dates.qs.tsv).

require 'json'
require_relative './steam_release.rb'
require_relative './sparql_tsv.rb'

PUBLICATION_DATE_PID = 'P577'
ROLE_PID = 'P3831'
EARLY_ACCESS_QID = 'Q17042291'
STATED_IN_PID = 'P248'
STEAM_QID = 'Q337535'
STEAM_PID = 'P1733'
RETRIEVED_PID = 'P813'

items_path, out_path = ARGV
abort "Usage: ruby #{File.basename(__FILE__)} items-file [out-file]" if items_path.nil?
out_path ||= File.join(__dir__, 'data', 'steam-release-dates.qs.tsv')

releases = SteamRelease.load
commands = []
counts = Hash.new(0)
File.readlines(items_path, chomp: true).each do |line|
  qid, appid = line.split("\t")
  next unless qid.to_s.match?(/\AQ\d+\z/) && appid.to_s.match?(/\A\d+\z/)

  app = releases[appid]
  release = app && app['release']
  if app.nil?
    counts['not fetched'] += 1
  elsif !app['found'] || release.nil?
    counts['not returned by Steam'] += 1
  elsif release['is_coming_soon']
    counts['coming soon'] += 1
  elsif release['steam_release_date'].to_i <= 0
    counts['released, but no date'] += 1
  else
    date = Time.at(release['steam_release_date'].to_i).utc.strftime('+%Y-%m-%dT00:00:00Z/11')
    qualifiers = release['is_early_access'] ? [ROLE_PID, EARLY_ACCESS_QID] : []
    commands << tsv_row([
      qid, PUBLICATION_DATE_PID, date, *qualifiers,
      STATED_IN_PID.sub('P', 'S'), STEAM_QID,
      STEAM_PID.sub('P', 'S'), "\"#{appid}\"",
      RETRIEVED_PID.sub('P', 'S'), "+#{app['retrieved']}T00:00:00Z/11"
    ])
    counts[release['is_early_access'] ? 'added (early access)' : 'added'] += 1
  end
end

File.write(out_path, commands.map { |c| "#{c}\n" }.join)
counts.sort.each { |reason, n| puts "#{n} #{reason}" }
puts "#{commands.count} statements written to #{out_path}."
