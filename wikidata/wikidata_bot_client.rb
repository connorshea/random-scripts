# Patches the mediawiki_api client to follow Wikidata's bot etiquette:
#
# - Sends `maxlag=5` with every edit and waits (indefinitely) while the servers
#   are lagged. Reads and logins don't send maxlag, so they aren't blocked.
#   https://www.mediawiki.org/wiki/Manual:Maxlag_parameter
# - Flags edits as bot edits (`bot=1`).
# - Sends a descriptive User-Agent. https://meta.wikimedia.org/wiki/User-Agent_policy
# - Retries on HTTP 429 and 5xx responses.
#
# Usage: require this file after loading `mediawiki_api` and
# `mediawiki_api-wikidata`. It patches MediawikiApi::Client, so any client
# created afterwards (including WikidataClient) is affected.

require_relative './wikidata_helper.rb'

module WikidataBotClient
  MAXLAG = 5
  # Max retries for HTTP 429/5xx errors. Maxlag waits are unlimited, since
  # lag can last for hours; Ctrl-C to stop.
  MAX_HTTP_ATTEMPTS = 10
  MAX_WAIT = 60
  # When the lag is well above MAXLAG, start backing off from a longer wait.
  HIGH_LAG = 10
  HIGH_LAG_MIN_WAIT = 30

  def initialize(*args, **kwargs)
    super
    @conn.headers['User-Agent'] = WikidataHelper::USER_AGENT
  end

  #
  # Add one or more new statements, with their qualifiers and references, to
  # an entity in a single edit (instead of separate wbcreateclaim,
  # wbsetqualifier and wbsetreference edits).
  #
  # @param entity_id [String] e.g. 'Q42'
  # @param statements [Array<Hash>] built with WikidataBotClient.statement
  # @param summary [String, nil] optional edit summary
  # @return [MediawikiApi::Response]
  #
  def add_statements(entity_id, statements, summary: nil)
    params = {
      token_type: 'csrf',
      id: entity_id,
      data: { 'claims' => statements }.to_json
    }
    params[:summary] = summary unless summary.nil?
    action(:wbeditentity, params)
  end

  # Convenience wrapper for adding a single statement.
  def add_statement(entity_id, statement, summary: nil)
    add_statements(entity_id, [statement], summary: summary)
  end

  #
  # Build a statement hash for `add_statements`.
  #
  # @param property [String] e.g. 'P5794'
  # @param datavalue [Hash] e.g. { 'value' => 'foo', 'type' => 'string' },
  #   see WikidataBotClient.string_value / item_value
  # @param qualifiers [Hash] snaks keyed by property, in the same format
  #   `wbsetreference` takes for its `snaks` param
  # @param references [Array<Hash>] one snaks hash (same format) per reference
  #
  def self.statement(property:, datavalue:, qualifiers: {}, references: [])
    statement = {
      'type' => 'statement',
      'rank' => 'normal',
      'mainsnak' => {
        'snaktype' => 'value',
        'property' => property,
        'datavalue' => datavalue
      }
    }
    statement['qualifiers'] = qualifiers unless qualifiers.empty?
    statement['references'] = references.map { |snaks| { 'snaks' => snaks } } unless references.empty?
    statement
  end

  def self.string_value(value)
    { 'value' => value.to_s, 'type' => 'string' }
  end

  # @param qid [String, Integer] e.g. 'Q5' or 5
  def self.item_value(qid)
    numeric_id = qid.to_s.delete_prefix('Q').to_i
    {
      'value' => { 'entity-type' => 'item', 'numeric-id' => numeric_id, 'id' => "Q#{numeric_id}" },
      'type' => 'wikibase-entityid'
    }
  end

  protected

  def raw_action(name, params = {})
    # Only edits (requests that need a token) send maxlag and are flagged as
    # bot edits. Logins, token fetches and reads use `token_type: false`.
    # `bot` only takes effect if the account has the bot right (for bot
    # passwords, the "High-volume (bot) access" grant).
    params = params.merge(maxlag: MAXLAG, bot: 1) unless params[:token_type] == false

    lag_attempts = 0
    http_attempts = 0
    begin
      super(name, params)
    rescue MediawikiApi::ApiError => e
      raise unless e.code == 'maxlag'

      lag_attempts += 1
      wait = lag_wait(e, lag_attempts)
      warn "#{Time.now.strftime('%H:%M:%S')} Wikidata is lagged (#{e.info}), retrying in #{wait}s (attempt #{lag_attempts})..."
      sleep wait
      retry
    rescue MediawikiApi::HttpError => e
      http_attempts += 1
      raise unless (e.status == 429 || e.status >= 500) && http_attempts < MAX_HTTP_ATTEMPTS

      wait_before_retry("Wikidata returned HTTP #{e.status}", http_attempts, max: MAX_HTTP_ATTEMPTS)
      retry
    end
  end

  private

  # Back off 5s, 10s, 15s... up to MAX_WAIT, but wait at least
  # HIGH_LAG_MIN_WAIT when the lag is above HIGH_LAG.
  def lag_wait(error, attempts)
    wait = [5 * attempts, MAX_WAIT].min
    lag = error.response&.data&.dig('lag') || error.info[/([\d.]+) seconds lagged/, 1]
    wait = [wait, HIGH_LAG_MIN_WAIT].max if lag && lag.to_f > HIGH_LAG
    wait
  end

  def wait_before_retry(reason, attempts, max: nil)
    wait = [5 * attempts, MAX_WAIT].min
    progress = max ? "attempt #{attempts}/#{max}" : "attempt #{attempts}"
    warn "#{Time.now.strftime('%H:%M:%S')} #{reason}, retrying in #{wait}s (#{progress})..."
    sleep wait
  end
end

MediawikiApi::Client.prepend(WikidataBotClient)
