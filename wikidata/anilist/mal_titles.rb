# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'
require_relative './anilist_api.rb'

# Fetches the titles MyAnimeList has for an anime or manga ID, so they can be
# checked against AniList's titles before linking the two. Uses MAL's
# official API (https://myanimelist.net/apiconfig/references/api/v2), which
# needs MAL_CLIENT_ID: register a client at https://myanimelist.net/apiconfig
# to get one. Only the client ID is needed, sent in the X-MAL-CLIENT-ID
# header, which isn't logged.
#
# Responses are cached in data/mal_<type>.jsonl (one line per MAL ID), so each
# ID is only ever fetched once. 404s are cached too.
module MALTitles
  HOST = 'api.myanimelist.net'
  USER_AGENT = AniListAPI::USER_AGENT
  # MAL doesn't document a rate limit; this keeps well under any reasonable
  # one.
  REQUEST_INTERVAL = 1.25
  # How long to back off after a 429 if MAL doesn't say.
  RATE_LIMIT_TIMEOUT = 60
  MAX_ATTEMPTS = 6
  # Stop the run after this many IDs in a row fail, since MAL is probably
  # down, rather than spending a minute of retries on each remaining ID.
  MAX_CONSECUTIVE_FAILURES = 3
  CONNECTION_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT, SocketError,
    EOFError, IOError, OpenSSL::SSL::SSLError
  ].freeze
  TYPES = %w[anime manga].freeze

  # @return [String] path of the cache for a type ('anime' or 'manga').
  def self.cache_path(type)
    File.join(AniListAPI::DATA_DIR, "mal_#{validate_type(type)}.jsonl")
  end

  #
  # Load the cached MAL entries of a type.
  #
  # @return [Hash{String => Hash}] MAL ID (as a string) => cached entry, with
  #   'status' (HTTP status) and 'titles' (every title MAL has, any language).
  #
  def self.load(type)
    path = cache_path(type)
    return {} unless File.exist?(path)

    AniListAPI.truncate_incomplete_line(path)
    File.foreach(path).to_h do |line|
      entry = JSON.parse(line)
      [entry['mal_id'].to_s, entry]
    end
  end

  #
  # Fetch the titles of every MAL ID that isn't cached yet, appending each
  # result to the cache as it arrives, so an interrupted run loses nothing.
  #
  # @param ids [Array<String, Integer>]
  # @return [Integer] number of IDs that still aren't cached (failed requests).
  #
  def self.fetch_missing(type, ids)
    client_id = mal_client_id
    abort 'Set MAL_CLIENT_ID to a MyAnimeList API client ID, see https://myanimelist.net/apiconfig' if client_id.nil?

    cached = load(type)
    todo = ids.map(&:to_s).uniq.reject { |id| cached.key?(id) }
    AniListAPI.log "#{ids.uniq.count} MAL #{type} IDs to check, #{todo.count} not cached yet."
    return 0 if todo.empty?

    minutes = (todo.count * REQUEST_INTERVAL / 60.0).ceil
    AniListAPI.log "Fetching them from the MAL API, about #{minutes} minute(s) at one request every #{REQUEST_INTERVAL}s."

    failed = 0
    consecutive_failures = 0
    # Connected lazily, and reconnected after a network error, by fetch_entry.
    http = Net::HTTP.new(HOST, 443)
    http.use_ssl = true
    File.open(cache_path(type), 'a') do |file|
      todo.each_with_index do |id, index|
        entry = fetch_entry(http, type, id, client_id)
        if entry.nil?
          failed += 1
          consecutive_failures += 1
          if consecutive_failures >= MAX_CONSECUTIVE_FAILURES
            AniListAPI.log "#{consecutive_failures} IDs in a row failed, so the MAL API is probably down. Stopping; " \
                           "what was fetched is saved. Run this again later to continue."
            return todo.count - index - 1 + failed
          end
        else
          consecutive_failures = 0
          file.write("#{JSON.generate(entry)}\n")
          file.flush
        end
        AniListAPI.log "#{index + 1}/#{todo.count} fetched." if ((index + 1) % 50).zero? || index + 1 == todo.count
      end
    end
    failed
  ensure
    http.finish if http&.started?
  end

  # @return [Hash, nil] the cache entry, or nil if it couldn't be fetched.
  def self.fetch_entry(http, type, id, client_id)
    attempts = 0
    loop do
      attempts += 1
      request = Net::HTTP::Get.new("/v2/#{type}/#{id}?fields=alternative_titles")
      request['X-MAL-CLIENT-ID'] = client_id
      request['User-Agent'] = USER_AGENT
      request['Accept'] = 'application/json'

      throttle
      response = begin
        http.start unless http.started?
        http.request(request)
      rescue *CONNECTION_ERRORS => e
        # Start over with a fresh connection on the next attempt.
        http.finish if http.started? rescue nil
        e
      end
      status = response.is_a?(Exception) ? 0 : response.code.to_i

      case status
      when 200
        titles = titles_from(JSON.parse(response.body))
        return { 'mal_id' => id.to_i, 'status' => 200, 'titles' => titles, 'fetched_at' => Time.now.utc.iso8601 }
      when 404
        return { 'mal_id' => id.to_i, 'status' => 404, 'titles' => [], 'fetched_at' => Time.now.utc.iso8601 }
      when 401, 403
        # Every request would fail the same way. What was fetched is saved.
        abort "[#{AniListAPI.timestamp}] MAL refused the request (HTTP #{status}). Check MAL_CLIENT_ID."
      end

      # 429, 5xx or a network
      # error: back off and retry.
      reason = response.is_a?(Exception) ? "#{response.class}: #{response.message}" : "HTTP #{status}"
      if attempts >= MAX_ATTEMPTS
        AniListAPI.log "Giving up on MAL #{type} #{id} for now (#{reason}). Run again to retry it."
        return nil
      end

      retry_after = response.is_a?(Exception) ? 0 : response['Retry-After'].to_i
      wait = if retry_after.positive?
               retry_after
             else
               status == 429 ? RATE_LIMIT_TIMEOUT : [2**attempts, 60].min
             end
      AniListAPI.wait_with_notice(wait, "MAL API request for MAL #{type} #{id} failed (#{reason}), retry #{attempts}/#{MAX_ATTEMPTS - 1}")
    end
  end

  # Every title in a MAL API v2 anime/manga object: the main title, plus the
  # English, Japanese and synonym alternative titles.
  def self.titles_from(data)
    alt = data['alternative_titles'] || {}
    titles = [data['title'], alt['en'], alt['ja']] + Array(alt['synonyms'])
    titles.compact.map(&:strip).reject(&:empty?).uniq
  end

  # @return [String, nil] MAL_CLIENT_ID, if set.
  def self.mal_client_id
    id = ENV['MAL_CLIENT_ID'].to_s.strip
    id.empty? ? nil : id
  end

  def self.throttle
    if @last_request_at
      wait = @last_request_at + REQUEST_INTERVAL - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep wait if wait.positive?
    end
    @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.validate_type(type)
    raise ArgumentError, "Invalid type #{type.inspect}, expected anime or manga" unless TYPES.include?(type)

    type
  end
end
