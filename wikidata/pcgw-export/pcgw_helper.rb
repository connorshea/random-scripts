# frozen_string_literal: true

module PcgwHelper
  require 'addressable/template'
  require 'open-uri'
  require 'json'

  class << self
    attr_accessor :pcgw_attrs
    attr_accessor :inverted_pcgw_attrs
  end

  # Semantic MediaWiki property names, can be found on Special:Browse.
  # e.g. https://pcgamingwiki.com/wiki/Special:Browse/:Half-2DLife-5F2
  # Note that PCGW intends to move to Cargo, so this may not work after 2019.
  self.pcgw_attrs = {
    developer: 'Developed by',
    publisher: 'Published by',
    engine: 'Uses engine',
    release_date: 'Release date',
    wikipedia: 'Wikipedia',
    cover: 'Cover',
    platforms: 'Available on',
    series: 'Part of series',
    steam_app_id: 'Steam AppID',
    wine_app_id: 'WineHQ AppID',
    gog_app_id: 'GOGcom page'
  }

  #
  # Make an API call.
  #
  # @param [String] conditions
  # @param [Array<String>] printouts
  # @param [Number] limit
  # @param [Number] offset
  #
  # @return [Hash] Ruby hash of the PCGW JSON response.
  # @example https://pcgamingwiki.com/w/api.php?action=askargs&conditions=Category:Games&printouts=Developed%20by|Release%20date&parameters=limit%3D500%7Coffset%3D#{offset}&format=json
  def pcgw_api_url(conditions, printouts, limit: 20, offset: 0)
    query_options = %i[
      format
      action
      conditions
      printouts
      parameters
    ]

    query_options_string = query_options.join(',')

    # limit 500, offset 100
    # &parameters=limit%3D500%7Coffset%3D100
    # unencoded: limit=500|offset=100

    template = Addressable::Template.new("https://www.pcgamingwiki.com/w/api.php{?#{query_options_string}}")
    template = template.expand(
      'action': 'askargs',
      'format': 'json',
      'conditions': conditions,
      'printouts': printouts.join('|'),
      'parameters': "limit=#{limit}|offset=#{offset}"
    )

    puts template.to_s if ENV['DEBUG']
    response = JSON.load(open(URI.parse(template.to_s)))
    puts JSON.pretty_generate(response) if ENV['DEBUG']
    response
  end

  #
  # Returns attributes for a given game.
  #
  # @param [String] game Game title
  # @param [Array<Symbol>] attributes An array of symbols for . Options are :developer, :publisher, :engine, :release_date, :wikipedia, :cover, :platforms, :series, :steam_app_id, :wine_app_id.
  #
  # @return [Hash] A hash from the JSON JSON
  #
  def get_attributes_for_game(game, attributes)
    attributes.map! { |attr| pcgw_attrs[attr] }

    response = pcgw_api_url(game, attributes, offset: 0, limit: 5)
    printouts = response.dig('query', 'results').values[0].dig('printouts')
    # puts JSON.pretty_generate(printouts)
    printouts.each_with_index do |(property, value), _index|
      if property == pcgw_attrs[:wikipedia]
        value = value.first
      elsif value&.first&.is_a?(Hash) && value.first.key?('fulltext')
        value.map! { |hash| { name: hash['fulltext'], full_url: hash['fullurl'] } }
      end

      { "#{property}": value }
    end

    printouts.transform_keys! { |key| pcgw_attrs.invert[key] }
  end
end
