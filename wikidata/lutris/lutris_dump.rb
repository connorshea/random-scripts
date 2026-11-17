# frozen_string_literal: true

##
# USAGE:
#
#   ruby lutris_dump.rb
#
# Downloads every game from the Lutris API (https://lutris.net/api/games)
# into data/lutris_games.jsonl, one game per line, which
# lutris_quickstatements.rb reads. If the download is interrupted, run the
# same command again to resume it from the last finished page.
#
# The API returns at most 250 games a page, so a full download is about
# 1,400 requests (~350,000 games).
#
# ENVIRONMENT VARIABLES:
#
# LUTRIS_REQUEST_INTERVAL (optional): seconds between requests, default 1.

require 'fileutils'
require 'json'
require 'net/http'

trap("SIGINT") { exit! }

HOST = 'lutris.net'
USER_AGENT = "Wikidata Lutris Importer (https://github.com/connorshea/random-scripts) Ruby/#{RUBY_VERSION}"
PAGE_SIZE = 250
REQUEST_INTERVAL = Float(ENV.fetch('LUTRIS_REQUEST_INTERVAL', '1'))
MAX_ATTEMPTS = 6

PATH = File.join(__dir__, 'data', 'lutris_games.jsonl')
# Games downloaded so far, and the last page that was fully written to it.
PARTIAL_PATH = "#{PATH}.partial"
PAGE_PATH = "#{PATH}.page"

# Fields that aren't needed for matching, dropped to keep the dump small.
DROPPED_FIELDS = %w[banner_url icon_url coverart shaders discord_id].freeze

def log(message)
  # Move off the progress line first, so it isn't overwritten.
  puts if @progress_shown
  @progress_shown = false
  puts "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
end

# Redraws one status line: a bar, pages done, games so far and the time
# left, estimated from the pages fetched since this run started (so a resumed
# run doesn't count the earlier pages as instant).
def show_progress(page, first_page_this_run, total, started_at)
  pages = total ? [(total.to_f / PAGE_SIZE).ceil, page].max : nil
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  done_this_run = page - first_page_this_run
  line = "Page #{page}/#{pages || '?'}, ~#{page * PAGE_SIZE} games"
  if pages
    fraction = page.to_f / pages
    width = 30
    filled = (fraction * width).round
    eta = (elapsed / done_this_run * (pages - page)).round
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

# @return [Hash] the parsed page. Exits if it can't be fetched.
def fetch_page(http, page)
  # Built by hand rather than following the response's "next" link, which
  # comes back HTML-escaped ("&amp;page=2").
  path = "/api/games?#{URI.encode_www_form(format: 'json', page: page, page_size: PAGE_SIZE)}"
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
      return body if body.is_a?(Hash) && body['results'].is_a?(Array)
    elsif status == 404
      # Django REST Framework answers a page past the end with 404.
      return { 'results' => [], 'next' => nil }
    end

    reason = if response.is_a?(Exception)
               "#{response.class}: #{response.message}"
             elsif status == 200
               'response was not the expected JSON'
             else
               "HTTP #{status}"
             end
    abort "#{"\n" if @progress_shown}[#{Time.now.strftime('%H:%M:%S')}] Giving up on page #{page} (#{reason}). Run this again to resume." if attempts >= MAX_ATTEMPTS

    retry_after = response.is_a?(Exception) ? 0 : response['Retry-After'].to_i
    wait = retry_after.positive? ? retry_after : [2**attempts * 5, 300].min
    log "WAITING: page #{page} failed (#{reason}), retry #{attempts}/#{MAX_ATTEMPTS - 1}. " \
        "Sleeping #{wait}s, until #{(Time.now + wait).strftime('%H:%M:%S')}."
    sleep wait
  end
end

FileUtils.mkdir_p(File.dirname(PATH))

last_page = File.exist?(PAGE_PATH) && File.exist?(PARTIAL_PATH) ? File.read(PAGE_PATH).to_i : 0
if last_page.positive?
  log "Resuming after page #{last_page}."
else
  File.write(PARTIAL_PATH, '')
end

page = last_page + 1
total = nil
started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
Net::HTTP.start(HOST, 443, use_ssl: true) do |http|
  loop do
    body = fetch_page(http, page)
    total ||= body['count']
    games = body['results']
    break if games.empty?

    File.open(PARTIAL_PATH, 'a') do |f|
      games.each { |game| f.write("#{JSON.generate(game.except(*DROPPED_FIELDS))}\n") }
    end
    File.write(PAGE_PATH, page.to_s)

    show_progress(page, last_page, total, started_at)
    break if body['next'].nil?

    page += 1
  end
end

# Games added or removed during the download shift the pages, so a game can
# show up twice. Keep the last copy of each.
games = {}
File.foreach(PARTIAL_PATH) do |line|
  game = JSON.parse(line)
  games[game['id']] = line
end
File.write("#{PATH}.tmp", games.sort_by { |id, _| id }.map { |_, line| line }.join)
File.rename("#{PATH}.tmp", PATH)
File.delete(PARTIAL_PATH, PAGE_PATH)
log "Saved #{games.count} Lutris games to #{PATH}#{total ? " (the API reported #{total})" : ''}."
