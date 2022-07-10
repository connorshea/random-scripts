
# frozen_string_literal: true
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'addressable'
  gem 'nokogiri'
end

require_relative './pcgw_helper.rb'

include PcgwHelper

puts PcgwHelper.get_attributes_for_game('Half-Life_2', %i[steam_app_id]).inspect
# => {:steam_app_id=>["220", "219", "323140", "466270", "290930"]}

puts PcgwHelper.get_attributes_for_game('Half-Life_2', %i[platforms]).inspect
# => {:platforms=>["Windows", "OS X", "Linux"]}

puts PcgwHelper.get_attributes_for_game('Half-Life_2', %i[page_name developer publisher engine release_date wikipedia platforms steam_app_id strategy_wiki_id]).inspect
# => {:page_name=>"Half-Life 2", :developer=>["Company:Valve Corporation"], :publisher=>["Company:Sierra Entertainment", "Company:Valve Corporation", "Company:1C-SoftClub"], :engine=>["Engine:Source"], :release_date=>["2004-11-16", "2010-05-26", "2013-05-09"], :wikipedia=>"Half-Life 2", :platforms=>["Windows", "OS X", "Linux"], :steam_app_id=>["220", "219", "323140", "466270", "290930"], :strategy_wiki_id=>["Half-Life 2"]}

puts PcgwHelper.get_attributes_for_game('The_Witcher_3:_Wild_Hunt', %i[page_name developer publisher engine release_date wikipedia platforms steam_app_id strategy_wiki_id]).inspect
# => {:page_name=>"The Witcher 3: Wild Hunt", :developer=>["Company:CD Projekt Red"], :publisher=>["Company:CD Projekt"], :engine=>["Engine:REDengine"], :release_date=>["2015-05-19"], :wikipedia=>"The Witcher 3: Wild Hunt", :platforms=>["Windows"], :steam_app_id=>["292030", "355880", "499450", "378648"], :strategy_wiki_id=>nil}

puts PcgwHelper.get_all_pages_with_property(:steam_app_id).inspect
