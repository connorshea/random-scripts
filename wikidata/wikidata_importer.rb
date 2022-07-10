require 'json'
require 'sparql/client'
require_relative 'wikidata_helper.rb'

# For comparing using Levenshtein Distance.
# https://stackoverflow.com/questions/16323571/measure-the-distance-between-two-strings-with-ruby
require "rubygems/text"

include WikidataHelper

# Killing the script mid-run gets caught by the rescues later in the script
# and fails to kill the script. This makes sure that the script can be killed
# normally.
trap("SIGINT") { exit! }

# A generic class for handling a bunch of repetitive Wikidata import code that
# gets used all over the place.
class WikidataImporter
  ENDPOINT = "https://query.wikidata.org/sparql"

  class << self
    def sparql_client
      SPARQL::Client.new(
        ENDPOINT,
        method: :get,
        headers: { 'User-Agent': "Connor's Random Ruby Scripts Data Fetcher/1.0 (connor.james.shea@gmail.com) Ruby 3.1" }
      )
    end

    # @abstract Subclass is expected to implement #query
    # @!method query
    #    Return a valid SPARQL query.

    def execute_query(*args)
      sparql_client.query(query(*args))
    end

    def wikidata_client
      wikidata_client = MediawikiApi::Wikidata::WikidataClient.new("https://www.wikidata.org/w/api.php")
      wikidata_client.log_in(ENV["WIKIDATA_USERNAME"], ENV["WIKIDATA_PASSWORD"])
      wikidata_client
    end

    # Compare game names with Levenshtein distance
    def games_have_same_name?(name1, name2)
      name1 = name1.downcase
      name2 = name2.downcase
      return true if name1 == name2

      levenshtein = Class.new.extend(Gem::Text).method(:levenshtein_distance)

      distance = levenshtein.call(name1, name2)
      return true if distance <= 2

      name1 = name1.gsub('&', 'and')
      name2 = name2.gsub('&', 'and')
      name1 = name1.gsub('deluxe', '').strip
      name2 = name2.gsub('deluxe', '').strip

      return true if name1 == name2

      return false
    end
  end
end
