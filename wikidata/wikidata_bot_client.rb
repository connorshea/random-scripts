# Patches the mediawiki_api client to follow Wikidata's bot etiquette:
#
# - Sends `maxlag=5` with every request and waits/retries when the servers are
#   lagged. https://www.mediawiki.org/wiki/Manual:Maxlag_parameter
# - Sends a descriptive User-Agent. https://meta.wikimedia.org/wiki/User-Agent_policy
# - Retries on HTTP 429 and 5xx responses.
#
# Usage: require this file after loading `mediawiki_api` and
# `mediawiki_api-wikidata`. It patches MediawikiApi::Client, so any client
# created afterwards (including WikidataClient) is affected.

require_relative './wikidata_helper.rb'

module WikidataBotClient
  MAXLAG = 5
  # Lag can persist for a while, so be patient before giving up.
  MAX_ATTEMPTS = 50
  MAX_WAIT = 60

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
    attempts = 0
    begin
      attempts += 1
      super(name, params.merge(maxlag: MAXLAG))
    rescue MediawikiApi::ApiError => e
      raise unless e.code == 'maxlag' && attempts < MAX_ATTEMPTS

      wait_before_retry("Wikidata is lagged (#{e.info})", attempts)
      retry
    rescue MediawikiApi::HttpError => e
      raise unless (e.status == 429 || e.status >= 500) && attempts < MAX_ATTEMPTS

      wait_before_retry("Wikidata returned HTTP #{e.status}", attempts)
      retry
    end
  end

  private

  def wait_before_retry(reason, attempts)
    wait = [5 * attempts, MAX_WAIT].min
    warn "#{reason}, retrying in #{wait}s (attempt #{attempts}/#{MAX_ATTEMPTS})..."
    sleep wait
  end
end

MediawikiApi::Client.prepend(WikidataBotClient)
