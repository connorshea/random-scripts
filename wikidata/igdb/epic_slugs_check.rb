# frozen_string_literal: true

##
# USAGE:
#
#   ruby epic_slugs_check.rb [batch-file]
#
# Checks that every Epic Games Store ID (P6278) in a QuickStatements batch
# (default data/igdb-epic-ids.qs.tsv) resolves to a store page, by looking the
# slug up with the GraphQL query the Epic store website itself uses
# (StorePageMapping). Epic has no public store API, so this is unofficial and
# may break or get blocked by Cloudflare; the script stops if the responses
# don't look right.
#
# Results are cached in data/epic_slugs.jsonl, one slug per line, so a stopped
# run continues where it left off. Then it writes
# data/epic-slugs-unresolved.tsv: the batch rows whose slug didn't resolve.

require 'date'
require 'json'
require 'net/http'
require_relative './steam_app_list.rb'

trap("SIGINT") { exit! }

CACHE_PATH = File.join(__dir__, 'data', 'epic_slugs.jsonl')
OUT_PATH = File.join(__dir__, 'data', 'epic-slugs-unresolved.tsv')
ENDPOINTS = %w[https://store.epicgames.com/graphql].freeze
REQUEST_INTERVAL = 1.0
MAX_ATTEMPTS = 4
# A slug that certainly exists, to check the query works before trusting a
# "not found".
KNOWN_SLUG = 'fortnite'

QUERY = <<~GRAPHQL
  query getMappingByPageSlug($pageSlug: String!) {
    StorePageMapping {
      mapping(pageSlug: $pageSlug) {
        pageSlug
        pageType
        productId
        sandboxId
      }
    }
  }
GRAPHQL

def log(message)
  SteamAppList.log(message)
end

# @return [Array<Array(String, String)>] [qid, slug] for each P6278 command.
def batch_slugs(path)
  File.foreach(path).filter_map do |line|
    qid, pid, value = line.chomp.split("\t")
    [qid, value.delete('"')] if pid == 'P6278'
  end
end

def load_cache
  return {} unless File.exist?(CACHE_PATH)

  File.foreach(CACHE_PATH).to_h do |line|
    entry = JSON.parse(line)
    [entry['slug'], entry]
  end
end

def throttle
  if @last_request_at
    wait = @last_request_at + REQUEST_INTERVAL - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep wait if wait.positive?
  end
  @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

#
# Look a slug up.
#
# @return [Hash] { 'found' => true/false, 'mapping' => ..., 'errors' => ... },
#   or { 'error' => message } if the request failed or the response didn't
#   look like a GraphQL response.
#
def lookup(uri, slug)
  attempts = 0
  loop do
    attempts += 1
    throttle
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request['User-Agent'] = SteamAppList::USER_AGENT
    request.body = JSON.generate(query: QUERY, variables: { pageSlug: slug })

    begin
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.request(request) }
    rescue StandardError => e
      return { 'error' => "#{e.class}: #{e.message}" } if attempts >= MAX_ATTEMPTS

      sleep 2**attempts
      next
    end

    body = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      nil
    end

    if body.is_a?(Hash) && body.key?('data')
      mapping = body.dig('data', 'StorePageMapping', 'mapping')
      return { 'found' => !mapping.nil?, 'mapping' => mapping, 'errors' => body['errors'] }
    end

    reason = "HTTP #{response.code}: #{response.body.to_s[0, 200].gsub(/\s+/, ' ')}"
    # 429 and 5xx are worth retrying; a Cloudflare challenge (403 with HTML)
    # isn't.
    if attempts >= MAX_ATTEMPTS || !(response.code == '429' || response.code.start_with?('5'))
      return { 'error' => reason }
    end

    sleep(response['Retry-After'].to_i.positive? ? response['Retry-After'].to_i : 2**attempts * 5)
  end
end

# The first endpoint that finds KNOWN_SLUG.
def pick_endpoint
  ENDPOINTS.each do |url|
    uri = URI(url)
    result = lookup(uri, KNOWN_SLUG)
    if result['found']
      log "Using #{url}."
      return uri
    end

    log "#{url} didn't work: #{result['error'] || "#{KNOWN_SLUG} not found, errors: #{JSON.generate(result['errors'])[0, 300]}"}"
  end
  abort "[#{SteamAppList.timestamp}] No endpoint works. Epic has probably changed or blocked the query."
end

batch_path = ARGV[0] || File.join(__dir__, 'data', 'igdb-epic-ids.qs.tsv')
abort "#{batch_path} doesn't exist." unless File.exist?(batch_path)

rows = batch_slugs(batch_path)
cache = load_cache
todo = rows.map(&:last).uniq.reject { |slug| cache.key?(slug) }
log "#{rows.count} Epic IDs in #{batch_path}, #{todo.count} not checked yet."

unless todo.empty?
  uri = pick_endpoint
  log "About #{(todo.count * REQUEST_INTERVAL / 60.0).ceil} minute(s) at one request every #{REQUEST_INTERVAL}s."
  consecutive_failures = 0
  File.open(CACHE_PATH, 'a') do |file|
    todo.each_with_index do |slug, index|
      result = lookup(uri, slug)
      if result.key?('error')
        consecutive_failures += 1
        log "#{slug}: #{result['error']}"
        abort "[#{SteamAppList.timestamp}] 3 failures in a row, stopping. What was checked is saved; run again to continue." if consecutive_failures >= 3
        next
      end

      consecutive_failures = 0
      entry = { 'slug' => slug, 'retrieved' => Date.today.iso8601 }.merge(result)
      entry.delete('errors') if entry['errors'].nil?
      file.puts JSON.generate(entry)
      file.flush
      cache[slug] = entry
      log "#{index + 1}/#{todo.count} checked." if ((index + 1) % 50).zero? || index + 1 == todo.count
    end
  end
end

unresolved = rows.select { |_qid, slug| cache[slug] && !cache[slug]['found'] }
unchecked = rows.count { |_qid, slug| cache[slug].nil? }
File.open(OUT_PATH, 'w') do |file|
  file.puts "qid\tslug\terrors"
  unresolved.each do |qid, slug|
    file.puts [qid, slug, cache[slug]['errors'] ? JSON.generate(cache[slug]['errors'])[0, 300] : ''].join("\t")
  end
end

page_types = rows.filter_map { |_qid, slug| cache.dig(slug, 'mapping', 'pageType') }.tally
log "#{rows.count - unresolved.count - unchecked} resolved (page types: #{page_types.map { |t, n| "#{t} #{n}" }.join(', ')}), " \
    "#{unresolved.count} didn't, #{unchecked} not checked."
log "Wrote the unresolved ones to #{OUT_PATH}." if unresolved.any?
