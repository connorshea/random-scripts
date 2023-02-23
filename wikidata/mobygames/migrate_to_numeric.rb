# The goal of this script is to migrate MobyGames game IDs (P1933) on Wikidata
# from slugs to numeric IDs, e.g. `half-life-2` becomes `15564`.
#
# This change was made on MobyGames' side as part of the redesign of their
# entire website. It will make the identifiers more stable and we'll need
# to update them to be consistent anyway, since newly-created games in
# their DB won't have slug-based URLs available. Thankfully, they've
# maintained redirects from the slug URLs to the new numeric ID URLs,
# so we can use those redirects to update all MobyGames game IDs we have in
# Wikidata.
#
# Old URL: https://www.mobygames.com/game/half-life-2/
# New URL: https://www.mobygames.com/game/15564/

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'sparql-client'
  gem 'nokogiri'
  gem 'ruby-progressbar', '~> 1.10'
  gem 'wikidatum', '~> 0.3.3'
end

require 'wikidatum'
require 'sparql/client'
require 'json'
require 'net/http'

