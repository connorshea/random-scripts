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
