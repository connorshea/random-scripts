# frozen_string_literal: true

##
# USAGE:
#
#   PCGW_USERNAME=... PCGW_PASSWORD=... ruby pcgw_dump.rb
#
# Downloads every row of PCGamingWiki's Cargo "Game" table (one per game
# article, from its {{Infobox game}}) into data/pcgw_games.jsonl, one game per
# line, which pcgw_quickstatements.rb reads. If the download is interrupted,
# run the same command again to resume it.
#
# Cargo returns at most 500 rows a request, so a full download is about 115
# requests (~57,000 games).
#
# ENVIRONMENT VARIABLES:
#
# PCGW_USERNAME, PCGW_PASSWORD (required): a PCGamingWiki bot password
#   (Special:BotPasswords; the username looks like "YourName@dumper"). Since
#   August 2026 PCGamingWiki only allows Cargo queries from logged-in users.
#   The password is only sent to www.pcgamingwiki.com and isn't logged.
# PCGW_REQUEST_INTERVAL (optional): seconds between requests, default 1.5.
#   PCGamingWiki allows 60 requests a minute, and blocks the IP for 60 seconds
#   when that's exceeded.

require 'cgi'
require 'fileutils'
require 'json'
require 'net/http'

trap("SIGINT") { exit! }

HOST = 'www.pcgamingwiki.com'
# PCGamingWiki asks for "clientname/version (contact) framework/version".
USER_AGENT = "WikidataPCGWImporter/1.0 (https://github.com/connorshea/random-scripts) Ruby/#{RUBY_VERSION}"
PAGE_SIZE = 500 # Cargo's maximum
REQUEST_INTERVAL = Float(ENV.fetch('PCGW_REQUEST_INTERVAL', '1.5'))
# A 429 blocks the IP for 60 seconds.
RATE_LIMIT_WAIT = 65
MAX_ATTEMPTS = 6
USERNAME = ENV.fetch('PCGW_USERNAME', '')
PASSWORD = ENV.fetch('PCGW_PASSWORD', '')
if USERNAME.empty? || PASSWORD.empty?
  abort 'Set PCGW_USERNAME and PCGW_PASSWORD to a PCGamingWiki bot password (Special:BotPasswords). ' \
        'PCGamingWiki only allows Cargo queries from logged-in users.'
end

PATH = File.join(__dir__, 'data', 'pcgw_games.jsonl')
# Games downloaded so far, and the highest page ID written to it.
PARTIAL_PATH = "#{PATH}.partial"
LAST_ID_PATH = "#{PATH}.last_id"

# Cargo field => key in the dump.
FIELDS = {
  '_pageID' => 'page_id',
  '_pageName' => 'page_name',
  'Steam_AppID' => 'steam',
  'GOGcom_ID' => 'gog',
  'Developers' => 'developers',
  'Publishers' => 'publishers',
  'Released' => 'released',
  'Series' => 'series',
  'Wikipedia' => 'wikipedia',
  'StrategyWiki' => 'strategywiki'
}.freeze
# List fields, and the delimiter Cargo joins their values with.
LIST_FIELDS = {
  'steam' => ',', 'gog' => ',', 'developers' => ',', 'publishers' => ',', 'series' => ',', 'released' => ';'
}.freeze

def log(message)
  # Move off the progress line first, so it isn't overwritten.
  puts if @progress_shown
  @progress_shown = false
  puts "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
end

# Redraws one status line: a bar, games so far and the time left, estimated
# from the games fetched since this run started (so a resumed run doesn't count
# the earlier games as instant).
def show_progress(count, first_count_this_run, total, started_at)
  line = "#{count}/#{total || '?'} games"
  done_this_run = count - first_count_this_run
  if total&.positive? && done_this_run.positive?
    fraction = [count.to_f / total, 1].min
    width = 30
    filled = (fraction * width).round
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    eta = [(elapsed / done_this_run * (total - count)).round, 0].max
    line = "[#{'#' * filled}#{'.' * (width - filled)}] #{(fraction * 100).floor}% #{line}, " \
           "#{format('%d:%02d:%02d', eta / 3600, eta / 60 % 60, eta % 60)} left"
  end
  # \e[K clears the rest of the previous, possibly longer, line.
  print "\r#{line}\e[K"
  $stdout.flush
  @progress_shown = true
end

def throttle
  if @last_request_at
    wait = @last_request_at + REQUEST_INTERVAL - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep wait if wait.positive?
  end
  @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# Session cookies from the login, sent with every request.
COOKIES = {}

# Sends one API request, with retries for network errors, server errors and
# rate limiting. Returns the parsed JSON. Exits if it keeps failing.
def api_request(http, params, method: :post)
  params = { format: 'json', formatversion: 2 }.merge(params)
  attempts = 0
  loop do
    attempts += 1
    request = if method == :get
                Net::HTTP::Get.new("/w/api.php?#{URI.encode_www_form(params)}")
              else
                Net::HTTP::Post.new('/w/api.php').tap { |r| r.set_form_data(params) }
              end
    request['User-Agent'] = USER_AGENT
    request['Accept'] = 'application/json'
    request['Cookie'] = COOKIES.map { |k, v| "#{k}=#{v}" }.join('; ') unless COOKIES.empty?

    throttle
    response = begin
      http.request(request)
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, EOFError, OpenSSL::SSL::SSLError => e
      e
    end
    status = response.is_a?(Exception) ? 0 : response.code.to_i

    unless response.is_a?(Exception)
      (response.get_fields('set-cookie') || []).each do |cookie|
        name, value = cookie.split(';', 2).first.split('=', 2)
        COOKIES[name.strip] = value.to_s.strip
      end
    end

    if status == 200
      body = (JSON.parse(response.body) rescue nil)
      return body if body.is_a?(Hash)
    end

    reason = if response.is_a?(Exception)
               "#{response.class}: #{response.message}"
             elsif status == 200
               'response was not JSON'
             else
               "HTTP #{status}"
             end
    abort "#{"\n" if @progress_shown}[#{Time.now.strftime('%H:%M:%S')}] Giving up (#{reason}). Run this again to resume." if attempts >= MAX_ATTEMPTS

    retry_after = response.is_a?(Exception) ? 0 : response['Retry-After'].to_i
    wait = if status == 429
             [retry_after, RATE_LIMIT_WAIT].max
           elsif retry_after.positive?
             retry_after
           else
             [2**attempts * 5, 300].min
           end
    log "WAITING: request failed (#{reason}), retry #{attempts}/#{MAX_ATTEMPTS - 1}. " \
        "Sleeping #{wait}s, until #{(Time.now + wait).strftime('%H:%M:%S')}."
    sleep wait
  end
end

# Logs in with the bot password (action=login), which sets the session cookies.
def login(http)
  COOKIES.clear
  token = api_request(http, { action: 'query', meta: 'tokens', type: 'login' }, method: :get)
          .dig('query', 'tokens', 'logintoken')
  abort "Couldn't get a login token from PCGamingWiki." if token.nil?

  result = api_request(http, { action: 'login', lgname: USERNAME, lgpassword: PASSWORD, lgtoken: token })['login']
  return if result&.dig('result') == 'Success'

  abort "#{"\n" if @progress_shown}Couldn't log in to PCGamingWiki as #{USERNAME}: " \
        "#{result&.dig('reason') || result&.dig('result') || 'no response'}"
end

# Runs a cargoquery on the Game table and returns its rows (the "title"
# objects). Logs in again once if the session has expired. Exits on any other
# API error, since retrying a bad query won't fix it.
def cargo_query(http, params)
  # assert=user makes an expired session an error instead of an anonymous
  # request.
  params = { action: 'cargoquery', tables: 'Game', assert: 'user' }.merge(params)
  2.times do |i|
    body = api_request(http, params)
    return body['cargoquery'].map { |row| row['title'] } if body['cargoquery'].is_a?(Array)

    code = body.dig('error', 'code')
    if i.zero? && %w[assertuserfailed permissiondenied].include?(code)
      log 'Session expired, logging in again.'
      login(http)
      next
    end
    abort "#{"\n" if @progress_shown}PCGamingWiki API error: #{code}: #{body.dig('error', 'info') || body.inspect[0, 300]}"
  end
end

# Turns a Cargo row into the hash written to the dump: HTML entities decoded,
# list fields split into arrays, Page values without their namespace
# ("Company:Valve Corporation" -> "Valve Corporation"), and empty values nil.
def clean_row(row)
  FIELDS.values.to_h do |key|
    value = CGI.unescapeHTML(row[key].to_s).strip
    value = if key == 'page_id'
              value.to_i
            elsif (delimiter = LIST_FIELDS[key])
              value.split(delimiter).map(&:strip).reject(&:empty?)
            else
              value.empty? ? nil : value
            end
    value = value.map { |v| v.sub(/\ACompany:/, '') } if %w[developers publishers].include?(key)
    value = value.map { |v| v.sub(/\ASeries:/, '') } if key == 'series'
    [key, value]
  end
end

FileUtils.mkdir_p(File.dirname(PATH))

last_id = File.exist?(LAST_ID_PATH) && File.exist?(PARTIAL_PATH) ? File.read(LAST_ID_PATH).to_i : 0
count = 0
if last_id.positive?
  count = File.foreach(PARTIAL_PATH).count
  log "Resuming after page ID #{last_id} (#{count} games so far)."
else
  File.write(PARTIAL_PATH, '')
end

fields = FIELDS.map { |field, key| "Game.#{field}=#{key}" }.join(',')
first_count = count
started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
Net::HTTP.start(HOST, 443, use_ssl: true) do |http|
  login(http)
  total = cargo_query(http, fields: 'COUNT(DISTINCT Game._pageID)=count', limit: 1).first&.dig('count')&.to_i

  loop do
    # Paging by page ID rather than offset, so games added or deleted during
    # the download don't shift the pages.
    rows = cargo_query(
      http,
      fields: fields,
      where: "Game._pageID > #{last_id}",
      order_by: 'Game._pageID',
      limit: PAGE_SIZE
    )
    break if rows.empty?

    games = rows.map { |row| clean_row(row) }
    File.open(PARTIAL_PATH, 'a') do |f|
      games.each { |game| f.write("#{JSON.generate(game)}\n") }
    end
    last_id = games.map { |g| g['page_id'] }.max
    File.write(LAST_ID_PATH, last_id.to_s)
    count += games.length

    show_progress(count, first_count, total, started_at)
    break if rows.length < PAGE_SIZE
  end
end

# A page with several {{Infobox game}} templates has several rows. Keep the
# first of each.
games = {}
File.foreach(PARTIAL_PATH) do |line|
  game = JSON.parse(line)
  games[game['page_id']] ||= line
end
File.write("#{PATH}.tmp", games.sort_by { |id, _| id }.map { |_, line| line }.join)
File.rename("#{PATH}.tmp", PATH)
File.delete(PARTIAL_PATH, LAST_ID_PATH)
log "Saved #{games.count} PCGamingWiki games to #{PATH}."
