# frozen_string_literal: true

require 'json'
require 'net/http'
require_relative './steam_app_list.rb'

# Fetches the platforms (Windows, macOS, Linux) Steam lists for app IDs, for
# the platform (P400) qualifiers on Steam application ID (P1733) and
# distributed by (P750) Steam statements. Steam's app list doesn't include
# platforms, so these come from IStoreBrowseService/GetItems, which takes
# many app IDs per request.
#
# Results are cached in data/steam_platforms.jsonl, one app per line, and only
# missing app IDs are fetched. An app Steam doesn't return is cached with
# "platforms": null, so it isn't requested again.
module SteamPlatforms
  PATH = File.join(__dir__, 'data', 'steam_platforms.jsonl')
  BATCH_SIZE = 100

  # Steam's platform flags => Wikidata items.
  PLATFORM_QIDS = {
    'windows' => 'Q1406',
    'mac' => 'Q14116',
    'steamos_linux' => 'Q388'
  }.freeze

  #
  # @return [Hash{String => Array<String>, nil}] app ID => platform QIDs, or
  #   nil for an app Steam didn't return. Apps that haven't been fetched are
  #   missing.
  #
  def self.load
    return {} unless File.exist?(PATH)

    File.foreach(PATH).to_h do |line|
      app = JSON.parse(line)
      [app['appid'].to_s, app['platforms']&.map { |p| PLATFORM_QIDS.fetch(p) }]
    end
  end

  # @param app_ids [Array<String>]
  def self.fetch_missing(app_ids)
    cached = load
    missing = app_ids.map(&:to_s).uniq.reject { |id| cached.key?(id) }
    SteamAppList.log "#{app_ids.uniq.count} app IDs, #{missing.count} not fetched yet."
    return if missing.empty?

    key = ENV['STEAM_API_KEY'].to_s
    FileUtils.mkdir_p(File.dirname(PATH))
    Net::HTTP.start(SteamAppList::HOST, 443, use_ssl: true) do |http|
      File.open(PATH, 'a') do |file|
        missing.each_slice(BATCH_SIZE).with_index do |batch, i|
          platforms = fetch_batch(http, batch, key)
          abort "[#{SteamAppList.timestamp}] Stopped. What was fetched is saved; run it again to continue." if platforms.nil?

          batch.each do |id|
            file.puts JSON.generate({ 'appid' => id.to_i, 'platforms' => platforms[id] })
          end
          file.flush
          SteamAppList.log "#{[(i + 1) * BATCH_SIZE, missing.count].min}/#{missing.count} fetched."
        end
      end
    end
  end

  # @return [Hash{String => Array<String>}, nil] app ID => Steam platform flags
  #   that are true, for the apps Steam returned; nil if the request failed.
  def self.fetch_batch(http, batch, key)
    input = {
      ids: batch.map { |id| { appid: id.to_i } },
      context: { language: 'english', country_code: 'US', steam_realm: 1 },
      data_request: { include_platforms: true }
    }
    params = { input_json: JSON.generate(input) }
    params[:key] = key unless key.empty?
    body = SteamAppList.get(http, "/IStoreBrowseService/GetItems/v1/?#{URI.encode_www_form(params)}", "IStoreBrowseService/GetItems for #{batch.first}..#{batch.last}")
    return nil if body.nil?

    items = body.dig('response', 'store_items')
    if items.nil?
      SteamAppList.log "Unexpected response: #{JSON.generate(body)[0, 500]}"
      return nil
    end

    items.each_with_object({}) do |item, result|
      next unless item['success'] == 1 && item['platforms'].is_a?(Hash)

      result[item['appid'].to_s] = PLATFORM_QIDS.keys.select { |flag| item['platforms'][flag] == true }
    end
  end
end
