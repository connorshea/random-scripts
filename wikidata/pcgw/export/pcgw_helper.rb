# frozen_string_literal: true

module PcgwHelper
  require 'addressable/template'
  require 'addressable/uri'
  require 'open-uri'
  require 'json'

  class << self
    attr_accessor :pcgw_attrs
    attr_accessor :pcgw_attrs_output
  end

  # Cargo properties.
  # Semantic MediaWiki is (mostly) kill, so we can't use that anymore.
  self.pcgw_attrs = {
    page_name: 'Infobox_game._pageName=Name',
    developer: 'Infobox_game.Developers',
    publisher: 'Infobox_game.Publishers',
    engine: 'Infobox_game.Engines',
    release_date: 'Infobox_game.Released',
    wikipedia: 'Infobox_game.Wikipedia',
    platforms: 'Infobox_game.Available_on',
    steam_app_id: 'Infobox_game.Steam_AppID',
    strategy_wiki_id: 'Infobox_game.StrategyWiki'
    
    # The following are not available in Cargo (yet?):
    # humble_store_id: 'Humble Store ID',
    # epic_games_store_id: 'Epic Games Store ID',
    # wine_app_id: 'WineHQ AppID'
    #
    # This one is available, but only the numeric ID and not the URL ID :(
    # gog_app_id: 'Infobox_game.GOGcom_ID',
    #
    # This one is available in Cargo but never used:
    # cover: 'Infobox_game.Cover_URL',
    # series: 'Infobox_game.Series',
  }.freeze

  # For some god-foresaken reason, the response has different attribute names :|
  # So we have to have this to handle it.
  self.pcgw_attrs_output = {
    page_name: 'Name',
    developer: 'Developers',
    publisher: 'Publishers',
    engine: 'Engines',
    release_date: 'Released',
    wikipedia: 'Wikipedia',
    platforms: 'Available on',
    steam_app_id: 'Steam AppID',
    strategy_wiki_id: 'StrategyWiki'
  }.freeze

  NON_ARRAY_PROPS = [:page_name, :wikipedia, :release_date]

  #
  # Make an API call.
  #
  # @param attributes [Array<String>]
  # @param where [String] the "Where" query, for example 'Infobox_game.Steam_AppID HOLDS "123"'
  # @param limit [Number]
  # @param offset [Number]
  #
  # @return [Hash] Ruby hash of the PCGW JSON response.
  # @example https://pcgamingwiki.com/w/api.php?action=askargs&conditions=Category:Games&printouts=Developed%20by|Release%20date&parameters=limit%3D500%7Coffset%3D#{offset}&format=json
  def pcgw_api_url(attributes, where:, limit: 20, offset: 0)
    query_options_string = %i[
      action
      format
      tables
      fields
      where
      limit
      offset
    ].join(',')

    template = Addressable::Template.new("https://www.pcgamingwiki.com/w/api.php{?#{query_options_string}}").expand(
      'action': 'cargoquery',
      'format': 'json',
      'tables': 'Infobox_game',
      'fields': pcgw_attrs.values_at(*attributes.map(&:to_sym)).join(','),
      'where': where,
      'limit': limit,
      'offset': offset
    )

    template_string = template.to_s
    puts template_string if ENV['DEBUG']
    response = JSON.load(URI.open(URI.parse(template_string)))
    puts JSON.pretty_generate(response) if ENV['DEBUG']
    response
  end

  #
  # Returns attributes for a given game.
  #
  # @param game [String] Game title, in a format like 'Half-Life_2' (from the PCGW URL).
  # @param attributes [Array<Symbol>] An array of symbols for attributes. Options are :page_name, :developer, :publisher, :engine, :release_date, :wikipedia, :platforms, :steam_app_id, :gog_app_id.
  #
  # @return [Hash] A hash from the JSON
  def get_attributes_for_game(game, attributes)
    invalid_keys = attributes.difference(pcgw_attrs.keys)
    raise ArgumentError, "The following attributes are not valid: #{invalid_keys.join(', ')}" unless invalid_keys.empty?

    response = pcgw_api_url(attributes, where: "Infobox_game._pageName=\"#{game.gsub('_', ' ')}\"", offset: 0, limit: 5)
    results = response.dig('cargoquery', 0, 'title')
    # Because it returns an array when there are no values under the title
    # key, rather than an empty object... for some reason.
    return {} if results.is_a?(Array)

    # The Cargo API returns the precision of the release date, but we do not care about that, so delete it.
    results.delete('Released__precision') if results.key?('Released__precision')

    puts JSON.pretty_generate(results) if ENV['DEBUG']

    results.transform_keys! { |key| pcgw_attrs_output.invert[key] }
    results.each_pair do |property, value|
      results[property] = value.split(',').map(&:strip) if !NON_ARRAY_PROPS.include?(property)
      # The release date is in a format like "2010-05-10;2013-06-02" when there's more than one release date.
      results[property] = value.split(';') if property == :release_date
    end

    # The Cargo API doesn't include the key-value pair at all if the value is null,
    # and that's stupid, so we're gonna fix it.
    attributes.difference(results.keys).each do |attrib|
      results[attrib] = nil
    end

    results
  end

  # Recursively calls the PCGamingWiki API to create an array of pages with specific properties.
  #
  # Returns an array of hashes like so:
  # ```json
  # [
  #   {
  #     page_name: "Bloodlines of Prima",
  #     steam_app_id: "686090"
  #   },
  #   {
  #     page_name: "BloodLust 2: Nemesis",
  #     steam_app_id: "758080"
  #   }
  # ]
  # ```
  #
  # @param property_symbol [Symbol] The name of a PCGW attribute from `pcgw_attrs`.
  # @param limit [Integer] The pagination page size limit, generally this should be left alone.
  # @param offset [Integer] The pagination record offset, generally this should be left alone.
  # @return [Array<Hash>]
  def get_all_pages_with_property(property_symbol, limit: 100, offset: 0)
    all_pages = []
    pages = get_pages_with_property(property_symbol, limit: limit, offset: offset).dig('cargoquery')
    pages.each do |result|
      result = result.dig('title')
      result.transform_keys! { |key| pcgw_attrs_output.invert[key] }

      result.each_pair do |property, value|
        result[property] = value.split(',').map(&:strip) if !NON_ARRAY_PROPS.include?(property)
        # The release date is in a format like "2010-05-10;2013-06-02" when there's more than one release date.
        result[property] = value.split(';') if property == :release_date
      end
      all_pages << result
    end
    # As long as the response from cargoquery isn't an empty array, keep going.
    unless pages.empty?
      puts "Continuing to pull down pages from offset #{offset}" if ENV['DEBUG']
      sleep 0.5
      all_pages.concat(get_all_pages_with_property(property_symbol, offset: offset + limit, limit: limit))
    end
    return all_pages
  end

  def get_pages_with_property(property_symbol, limit: 25, offset: 0)
    property = pcgw_attrs[property_symbol]
    query_options_string = %i[
      action
      format
      tables
      fields
      where
      limit
      offset
    ].join(',')

    template = Addressable::Template.new("https://www.pcgamingwiki.com/w/api.php{?#{query_options_string}}").expand(
      'action': 'cargoquery',
      'format': 'json',
      'tables': 'Infobox_game',
      'fields': [pcgw_attrs[:page_name], property].join(','),
      'where': "#{property} HOLDS LIKE \"%\"", # This is cursed, but for some reason "HOLDS NOT NULL" doesn't work.
      'limit': limit,
      'offset': offset
    )

    template_string = template.to_s
    puts template_string if ENV['DEBUG']
    response = JSON.load(URI.open(URI.parse(template_string)))
    puts JSON.pretty_generate(response) if ENV['DEBUG']
    response
  end

  def get_pcgw_attr_name(attr_name)
    return pcgw_attrs[attr_name]
  end
end
