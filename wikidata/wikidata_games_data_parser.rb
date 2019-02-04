require "json"
require "date"
require './wikidata_helper.rb'
include WikidataHelper

games = JSON.load(File.read('wikidata_games_data.json'))

pretty_game_hashes = []
platforms = []

games.each do |game|
  game['platforms'].each do |platform|
    platforms << platform['property_id']
  end
end

platforms.uniq!
platforms = get_english_names(platforms)

games.each do |game|
  releases = []
  pretty_game_hash = {}

  pretty_game_hash[:name] = game['name']
  pretty_game_hash[:wikidata_id] = game['id']
  pretty_game_hash[:genres] = game['genres'].map { |genre| genre['property_id'] }
  
  game['platforms'].each do |game_platform|
    release = {}
    platform = platforms.find { |platform| platform[:id] == game_platform["property_id"] }
    release[:name] = "#{game['name']} for #{platform[:name]}"
    release[:platform] = platform
    
    release_developers = []

    game['developers'].each do |developer|
      if developer['qualifiers'].nil?
        release_developers << developer['property_id']
      elsif developer['qualifiers']['platforms']&.include?(game_platform['property_id'])
        release_developers << developer['property_id']
      elsif developer['qualifiers'].keys.length > 1
        puts "Developers has unhandled qualifier case"
        puts developer['qualifiers']
      end
    end

    release[:developers] = release_developers

    release_publishers = []

    game['publishers'].each do |publisher|
      if publisher['qualifiers'].nil?
        release_publishers << publisher['property_id']
      elsif publisher['qualifiers']['platforms']&.include?(game_platform['property_id'])
        release_publishers << publisher['property_id']
      elsif publisher['qualifiers'].keys.length > 1
        puts "Publishers has unhandled qualifier case?"
        puts publisher['qualifiers']
      end
    end

    release[:publishers] = release_publishers

    publication_dates = []
    date_with_platform_exists = false
    game['release_dates'].each do |publication_date|
      if publication_date['qualifiers'].nil?
        publication_dates << publication_date['time']
      elsif publication_date['qualifiers']['platforms']&.include?(game_platform['property_id'])
        release[:release_date] = publication_date['time']
        date_with_platform_exists = true
      else
        publication_dates << publication_date['time']
      end
    end

    # # If a release date specifies a given platform, that release date should take precident.
    # # If no release date is specified for a given platform, we try to get the earliest date.
    # unless date_with_platform_exists
    #   publication_dates.sort! { |a, b| Date.parse(a) <=> Date.parse(b) }
    #   release[:release_date] = publication_dates.first
    # end

    releases << release
  end

  pretty_game_hash[:releases] = releases

  pretty_game_hashes << pretty_game_hash
end

puts JSON.pretty_generate(pretty_game_hashes)
