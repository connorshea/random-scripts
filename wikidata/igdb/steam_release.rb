# frozen_string_literal: true

require 'date'
require 'json'
require 'net/http'
require_relative './steam_app_list.rb'

# Fetches Steam's release information for app IDs: the release date, whether
# the app is "coming soon", and how precisely Steam shows the date (a full
# date, a month, a quarter, a year, or "To be announced"). Uses
# IStoreBrowseService/GetItems, 100 apps per request.
#
# Results are cached in data/steam_release.jsonl, one app per line, with
# Steam's `release` object as-is. Only missing app IDs are fetched. An app
# Steam doesn't return is cached with "found": false.
module SteamRelease
  PATH = File.join(__dir__, 'data', 'steam_release.jsonl')
  BATCH_SIZE = 100

  # @return [Hash{String => Hash}] app ID => cached line.
  def self.load
    return {} unless File.exist?(PATH)

    File.foreach(PATH).to_h do |line|
      app = JSON.parse(line)
      [app['appid'].to_s, app]
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
          items = fetch_batch(http, batch, key)
          abort "[#{SteamAppList.timestamp}] Stopped. What was fetched is saved; run it again to continue." if items.nil?

          batch.each do |id|
            item = items[id]
            line = { 'appid' => id.to_i, 'found' => !item.nil?, 'retrieved' => Date.today.iso8601 }
            line.merge!('name' => item['name'], 'visible' => item['visible'], 'release' => item['release']) unless item.nil?
            file.puts JSON.generate(line)
          end
          file.flush
          SteamAppList.log "#{[(i + 1) * BATCH_SIZE, missing.count].min}/#{missing.count} fetched."
        end
      end
    end
  end

  # @return [Hash{String => Hash}, nil] app ID => Steam's store item, for the
  #   apps Steam returned; nil if the request failed.
  def self.fetch_batch(http, batch, key)
    input = {
      ids: batch.map { |id| { appid: id.to_i } },
      context: { language: 'english', country_code: 'US', steam_realm: 1 },
      data_request: { include_release: true }
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
      result[item['appid'].to_s] = item if item['success'] == 1
    end
  end
end
