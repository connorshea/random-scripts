# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'net/http'

# Minimal AniList GraphQL client that downloads every anime or manga into a
# local dump, so the scripts in this directory can reuse it without hitting
# the API again.
#
# Dumps are JSON Lines files in data/ (one raw AniList media object per line),
# shared by every script that needs that media type. Downloads are written
# page by page and resume where they left off if interrupted.
#
# Uses plain Net::HTTP over a single keep-alive connection instead of
# graphql-client, which downloaded AniList's whole schema on every run.
module AniListAPI
  URI_ENDPOINT = URI('https://graphql.anilist.co')
  USER_AGENT = "AniList Wikidata Importer (https://github.com/connorshea/random-scripts) Ruby/#{RUBY_VERSION}"
  PER_PAGE = 50 # AniList's maximum.
  DATA_DIR = File.join(__dir__, 'data')

  # Every field any script in this directory needs, so one dump serves them all.
  FIELDS = {
    'ANIME' => <<~GRAPHQL,
      id
      idMal
      title { english romaji native }
      format
      season
      seasonYear
      status
      studios { nodes { name } }
    GRAPHQL
    'MANGA' => <<~GRAPHQL
      id
      idMal
      title { english romaji native }
      format
      status
    GRAPHQL
  }.freeze

  # Rate limiting, see https://docs.anilist.co/guide/rate-limiting
  #
  # AniList allows 90 requests/minute (currently degraded to 30/minute), plus
  # an unspecified burst limiter, and exceeding the limit earns a 1 minute
  # timeout. Every response includes X-RateLimit-Limit, so requests are spaced
  # evenly at that limit with some headroom, which also keeps the burst
  # limiter happy. Set ANILIST_REQUEST_INTERVAL (seconds) to pin the spacing.
  RATE_LIMIT_HEADROOM = 1.25
  # Assume the degraded 30/minute limit until a response says otherwise.
  DEFAULT_REQUEST_INTERVAL = 60.0 / 30 * RATE_LIMIT_HEADROOM
  FIXED_REQUEST_INTERVAL = ENV['ANILIST_REQUEST_INTERVAL']&.then { |v| Float(v) }
  # How long AniList's timeout lasts after exceeding the rate limit.
  RATE_LIMIT_TIMEOUT = 60
  MAX_ATTEMPTS = 10

  # @param type [String] 'ANIME' or 'MANGA'
  # @return [String] path of the finished dump for that media type.
  def self.dump_path(type)
    File.join(DATA_DIR, "anilist_#{validate_type(type).downcase}.jsonl")
  end

  #
  # Load every media entry of a type from the local dump, downloading it first
  # if `download` is truthy (by default, when USE_ANILIST_API is set).
  #
  # @param type [String] 'ANIME' or 'MANGA'
  # @return [Array<Hash>] raw AniList media hashes (camelCase keys)
  #
  def self.load(type, download: ENV['USE_ANILIST_API'])
    download(type) if download

    path = dump_path(type)
    unless File.exist?(path)
      abort "No AniList #{type.downcase} dump at #{path}. Download it with " \
            "`ruby #{File.join(__dir__, 'anilist_dump.rb')} #{type.downcase}` or set USE_ANILIST_API=1."
    end

    puts "Reading AniList #{type.downcase} from #{path} (downloaded #{File.mtime(path).strftime('%Y-%m-%d %H:%M')})."
    File.foreach(path).map { |line| JSON.parse(line) }
  end

  #
  # Download every media entry of a type into its dump. Progress is saved
  # after each page, so an interrupted download resumes on the next call. The
  # previous dump, if any, is only replaced once the new one is complete.
  #
  # @param type [String] 'ANIME' or 'MANGA'
  #
  def self.download(type)
    path = dump_path(type)
    partial_path = "#{path}.partial"
    progress_path = "#{partial_path}.page"
    FileUtils.mkdir_p(DATA_DIR)

    last_page = File.exist?(partial_path) && File.exist?(progress_path) ? File.read(progress_path).to_i : 0
    if last_page.positive?
      truncate_incomplete_line(partial_path)
      puts "Resuming the AniList #{type.downcase} download after page #{last_page}."
    else
      File.write(partial_path, '')
      puts "Downloading every #{type.downcase} from AniList into #{path}."
    end

    count = File.foreach(partial_path).count
    complete = File.open(partial_path, 'a') do |file|
      each_page(type, start_page: last_page + 1) do |page, media|
        file.write(media.map { |m| "#{JSON.generate(m)}\n" }.join)
        file.flush
        File.write(progress_path, page.to_s)
        count += media.length
        puts "Page #{page}: #{count} #{type.downcase} downloaded so far."
      end
    end

    abort "The AniList #{type.downcase} download stopped early. Run it again to resume." unless complete

    # Sorting by ID keeps pages stable across a resume, but a re-fetched page
    # can still repeat entries, so drop duplicates while finalizing.
    seen = {}
    File.open("#{path}.tmp", 'w') do |out|
      File.foreach(partial_path) do |line|
        id = JSON.parse(line)['id']
        next if seen[id]

        seen[id] = true
        out.write(line)
      end
    end
    File.rename("#{path}.tmp", path)
    File.delete(partial_path, progress_path)
    puts "Saved #{seen.size} #{type.downcase} to #{path}."
  end

  #
  # Yield each page of media of the given type, sorted by ID.
  #
  # @return [Boolean] true if every page was fetched, false if it stopped early.
  # @yieldparam page [Integer]
  # @yieldparam media [Array<Hash>]
  #
  def self.each_page(type, start_page: 1)
    query = <<~GRAPHQL
      query ($page: Int, $perPage: Int) {
        Page(page: $page, perPage: $perPage) {
          pageInfo { hasNextPage }
          media(type: #{validate_type(type)}, sort: ID) { #{FIELDS.fetch(type)} }
        }
      }
    GRAPHQL

    page = start_page
    Net::HTTP.start(URI_ENDPOINT.host, URI_ENDPOINT.port, use_ssl: true) do |http|
      loop do
        data = fetch_page(http, query, page)
        return false if data.nil?

        yield page, data['media']
        return true unless data.dig('pageInfo', 'hasNextPage')

        page += 1
      end
    end
  end

  def self.validate_type(type)
    raise ArgumentError, "Invalid type #{type.inspect}, expected ANIME or MANGA" unless FIELDS.key?(type)

    type
  end

  # If the process was killed mid-write, drop the partial last line so the
  # resumed download starts on a fresh line. That page is re-fetched anyway,
  # since its progress was never recorded.
  def self.truncate_incomplete_line(path)
    contents = File.binread(path)
    return if contents.empty? || contents.end_with?("\n")

    File.truncate(path, (contents.rindex("\n") || -1) + 1)
  end

  # @return [Hash, nil] the `Page` object, or nil on an unrecoverable error.
  def self.fetch_page(http, query, page)
    attempts = 0
    loop do
      attempts += 1

      request = Net::HTTP::Post.new(URI_ENDPOINT)
      request['User-Agent'] = USER_AGENT
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request.body = JSON.generate(query: query, variables: { page: page, perPage: PER_PAGE })

      throttle
      response = http.request(request)
      update_request_interval(response)
      status = response.code.to_i

      if (status == 429 || status >= 500) && attempts < MAX_ATTEMPTS
        wait = response['Retry-After'].to_i
        unless wait.positive?
          wait = status == 429 ? RATE_LIMIT_TIMEOUT : [2**attempts, 60].min
        end
        puts "AniList returned HTTP #{status}, retrying in #{wait}s (attempt #{attempts}/#{MAX_ATTEMPTS})."
        sleep wait
        next
      end

      wait_for_rate_limit_window(response)

      data = (JSON.parse(response.body) rescue nil)&.dig('data', 'Page')
      puts "Unexpected response on page #{page} (HTTP #{status}): #{response.body}" if data.nil?
      return data
    end
  end

  # Seconds to leave between the start of any two requests (retries included).
  def self.request_interval
    FIXED_REQUEST_INTERVAL || @request_interval || DEFAULT_REQUEST_INTERVAL
  end

  # Sleep until request_interval has passed since the previous request.
  def self.throttle
    if @last_request_at
      wait = @last_request_at + request_interval - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep wait if wait.positive?
    end
    @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Pace requests to the per-minute limit AniList reports in X-RateLimit-Limit.
  def self.update_request_interval(response)
    limit = response['X-RateLimit-Limit'].to_i
    return unless limit.positive?

    interval = 60.0 / limit * RATE_LIMIT_HEADROOM
    return if interval == @request_interval

    puts "AniList rate limit is #{limit}/minute, spacing requests #{interval.round(2)}s apart." unless FIXED_REQUEST_INTERVAL
    @request_interval = interval
  end

  # If a successful response used up the last request in the window, wait it
  # out rather than earning a 429 and a 1 minute timeout.
  def self.wait_for_rate_limit_window(response)
    return unless response['X-RateLimit-Remaining'] == '0'

    reset_at = response['X-RateLimit-Reset'].to_i
    wait = reset_at.positive? ? reset_at - Time.now.to_i + 1 : RATE_LIMIT_TIMEOUT
    return unless wait.positive?

    puts "AniList rate limit window used up, waiting #{wait}s."
    sleep wait
  end
end
