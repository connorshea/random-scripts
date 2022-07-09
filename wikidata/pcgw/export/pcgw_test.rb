
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
