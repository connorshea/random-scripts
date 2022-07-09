# frozen_string_literal: true

module OldPcgwHelper
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
    gog_app_id: 'GOGcom page',
    humble_store_id: 'Humble Store ID',
    epic_games_store_id: 'Epic Games Store ID',
    subtitles: 'Subtitles',
    strategy_wiki_id: 'StrategyWiki'
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
    response = JSON.load(URI.open(URI.parse(template.to_s)))
    puts JSON.pretty_generate(response) if ENV['DEBUG']
    response
  end

  #
  # Returns attributes for a given game.
  #
  # @param [String] game Game title
  # @param [Array<Symbol>] attributes An array of symbols for . Options are :developer, :publisher, :engine, :release_date, :wikipedia, :cover, :platforms, :series, :steam_app_id, :wine_app_id.
  #
  # @return [Hash] A hash from the JSON
  def get_attributes_for_game(game, attributes)
    attributes.map! { |attr| pcgw_attrs[attr] }

    response = pcgw_api_url(game, attributes, offset: 0, limit: 5)
    results = response.dig('query', 'results')
    return {} unless results.respond_to?(:values)
    printouts = results.values[0].dig('printouts')
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

  # Recursively calls the PCGamingWiki API to create an array of pages with specific properties.
  #
  # Returns an array of hashes like so:
  # ```json
  # {
  #   "printouts": {
  #     "Humble Store ID": [
  #       "control"
  #     ]
  #   },
  #   "fulltext": "Control",
  #   "fullurl": "https://www.pcgamingwiki.com/wiki/Control",
  #   "namespace": 0,
  #   "exists": "1",
  #   "displaytitle": "",
  #   "name": "Control"
  # }
  # ```
  #
  # @param property_symbol [Symbol] The name of a PCGW attribute from `pcgw_attrs`.
  # @param limit [Integer] The pagination page size limit, generally this should be left alone.
  # @param offset [Integer] The pagination record offset, generally this should be left alone.
  # @return [Array<Hash>]
  def get_all_pages_with_property(property_symbol, limit: 25, offset: 0)
    all_pages = []
    pages = get_pages_with_property(property_symbol, limit: limit, offset: offset)
    pages.dig('query', 'results').each do |key, result|
      result["name"] = key
      all_pages << result
    end
    if pages.key?('query-continue-offset')
      puts "Continuing to pull down pages from offset #{offset}" if ENV['DEBUG']
      all_pages.concat(get_all_pages_with_property(property_symbol, offset: pages['query-continue-offset'].to_i))
    end
    return all_pages
  end

  def get_pages_with_property(property_symbol, limit: 25, offset: 0)
    property = pcgw_attrs[property_symbol]

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
      'conditions': "#{property}::%2B",
      'printouts': property,
      'parameters': "order=desc|limit=#{limit}|offset=#{offset}"
    )

    # Have to replace %25 with % because Addressable is dumb and so is the MediaWiki API.
    template_string = template.to_s.gsub('%25', '%')
    puts template_string if ENV['DEBUG']
    response = JSON.load(URI.open(URI.parse(template_string)))
    puts JSON.pretty_generate(response) if ENV['DEBUG']
    response
  end

  def get_pcgw_attr_name(attr_name)
    return pcgw_attrs[attr_name]
  end
end
