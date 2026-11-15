# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'net/http'

# Downloads Steam's full list of apps (ID and name) into
# data/steam_app_list.jsonl, so Steam IDs can be checked against Steam's own
# names without a request per ID.
#
# Uses IStoreService/GetAppList, which pages through games, DLC and software,
# up to 50,000 apps per request. It needs STEAM_API_KEY, a free Steam Web API
# key (see https://steamcommunity.com/dev/apikey). The key is only sent to
# api.steampowered.com and never logged.
module SteamAppList
  HOST = 'api.steampowered.com'
  USER_AGENT = "Wikidata IGDB Importer (https://github.com/connorshea/random-scripts) Ruby/#{RUBY_VERSION}"
  PATH = File.join(__dir__, 'data', 'steam_app_list.jsonl')
  MAX_RESULTS = 50_000
  # A handful of requests in total, so this is just politeness.
  REQUEST_INTERVAL = 2
  MAX_ATTEMPTS = 6

  #
  # @return [Hash{String => String}, nil] app ID (as a string) => name, or nil
  #   if the list hasn't been downloaded.
  #
  def self.load
    return nil unless File.exist?(PATH)

    File.foreach(PATH).to_h do |line|
      app = JSON.parse(line)
      [app['appid'].to_s, app['name'].to_s]
    end
  end

  # Download the whole list, replacing the previous one once it's complete.
  def self.download
    key = ENV['STEAM_API_KEY'].to_s
    abort 'Set STEAM_API_KEY to a Steam Web API key, see https://steamcommunity.com/dev/apikey' if key.empty?

    FileUtils.mkdir_p(File.dirname(PATH))
    apps = download_store_service(key)
    abort "[#{timestamp}] The Steam app list download failed. Run it again." if apps.nil?

    apps = apps.uniq { |app| app['appid'] }.sort_by { |app| app['appid'] }
    File.write("#{PATH}.tmp", apps.map { |app| "#{JSON.generate(app)}\n" }.join)
    File.rename("#{PATH}.tmp", PATH)
    log "Saved #{apps.count} Steam apps to #{PATH}."
  end

  # @return [Array<Hash>, nil]
  def self.download_store_service(key)
    log 'Downloading the Steam app list from IStoreService/GetAppList.'
    apps = []
    last_appid = 0
    Net::HTTP.start(HOST, 443, use_ssl: true) do |http|
      loop do
        query = URI.encode_www_form(
          key: key,
          include_games: true,
          include_dlc: true,
          include_software: true,
          include_videos: false,
          include_hardware: false,
          max_results: MAX_RESULTS,
          last_appid: last_appid
        )
        body = get(http, "/IStoreService/GetAppList/v1/?#{query}", "IStoreService/GetAppList after app #{last_appid}")
        return nil if body.nil?

        response = body['response'] || {}
        page = (response['apps'] || []).map { |app| { 'appid' => app['appid'], 'name' => app['name'] } }
        apps.concat(page)
        log "#{apps.count} apps so far (up to app #{page.last&.fetch('appid')})."
        break unless response['have_more_results']

        last_appid = response['last_appid']
      end
    end
    apps
  end

  # @param label [String] what's being fetched, for logs (never the URL, which
  #   contains the key).
  # @return [Hash, nil] the parsed JSON body.
  def self.get(http, path, label)
    attempts = 0
    loop do
      attempts += 1
      request = Net::HTTP::Get.new(path)
      request['User-Agent'] = USER_AGENT
      request['Accept'] = 'application/json'

      throttle
      response = begin
        http.request(request)
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, EOFError, OpenSSL::SSL::SSLError => e
        e
      end
      status = response.is_a?(Exception) ? 0 : response.code.to_i

      if status == 200
        body = (JSON.parse(response.body) rescue nil)
        return body unless body.nil?
      elsif [401, 403].include?(status)
        log "#{label} was refused (HTTP #{status}). Check STEAM_API_KEY."
        return nil
      end

      reason = if response.is_a?(Exception)
                 "#{response.class}: #{response.message}"
               elsif status == 200
                 'response was not JSON'
               else
                 "HTTP #{status}"
               end
      if attempts >= MAX_ATTEMPTS
        log "Giving up on #{label} (#{reason})."
        return nil
      end

      retry_after = response.is_a?(Exception) ? 0 : response['Retry-After'].to_i
      wait = retry_after.positive? ? retry_after : [2**attempts * 5, 300].min
      wait_with_notice(wait, "#{label} failed (#{reason}), retry #{attempts}/#{MAX_ATTEMPTS - 1}")
    end
  end

  def self.throttle
    if @last_request_at
      wait = @last_request_at + REQUEST_INTERVAL - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep wait if wait.positive?
    end
    @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Sleep for longer than the usual request spacing, saying why and until when.
  def self.wait_with_notice(seconds, reason)
    log "WAITING: #{reason}. Sleeping #{seconds}s, until #{(Time.now + seconds).strftime('%H:%M:%S')}."
    sleep seconds
    log 'Done waiting, resuming.'
  end

  def self.log(message)
    puts "[#{timestamp}] #{message}"
  end

  def self.timestamp
    Time.now.strftime('%Y-%m-%d %H:%M:%S')
  end
end
