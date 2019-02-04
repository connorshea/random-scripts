require "json"
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
      elsif developer['qualifiers']['platforms'].include?(game_platform['property_id'])
        puts developer['qualifiers']['platforms']
        release_developers << developer['property_id']
      end
    end

    release[:developers] = release_developers

    release_publishers = []

    game['publishers'].each do |publisher|
      if publisher['qualifiers'].nil?
        release_publishers << publisher['property_id']
      elsif publisher['qualifiers']['platforms'].include?(game_platform['property_id'])
        puts publisher['qualifiers']['platforms']
        release_publishers << publisher['property_id']
      end
    end

    release[:publishers] = release_publishers

    releases << release
  end

  pretty_game_hash[:releases] = releases

  pretty_game_hashes << pretty_game_hash
end

puts JSON.pretty_generate(pretty_game_hashes)
