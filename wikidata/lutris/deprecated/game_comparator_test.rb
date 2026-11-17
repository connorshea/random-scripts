# NOTE: Not intended for use. Just meant to be an easy way of testing the
# game comparison method I wrote for the Lutris-to-Wikidata importer.

require "bundler/inline"

gemfile do
  gem 'rainbow', '~> 3.0'
end

# For comparing using Levenshtein Distance.
# https://stackoverflow.com/questions/16323571/measure-the-distance-between-two-strings-with-ruby
require "rubygems/text"

def games_have_same_name?(name1, name2)
  name1 = name1.downcase
  name2 = name2.downcase
  return true if name1 == name2

  levenshtein = Class.new.extend(Gem::Text).method(:levenshtein_distance)

  distance = levenshtein.call(name1, name2)
  puts distance.inspect
  # puts "Levenshtein distance of #{name1} to #{name2}: #{levenshtein.call(name1, name2)}"
  return true if distance <= 2

  name1 = name1.gsub('&', 'and')
  name2 = name2.gsub('&', 'and')
  name1 = name1.gsub('deluxe', '').strip
  name2 = name2.gsub('deluxe', '').strip

  return true if name1 == name2

  return false
end

pairs_that_should_match = [
  ["Crazy Cars - Hit the Road", "Crazy Cars: Hit the Road"],
  ["Cossacks: Art of War", "Cossacks: The Art of War"],
  ["Cook, Serve, Delicious! 2!!", "Cook, Serve, Delicious! 2"],
  ["CONSORTIUM", "Consortium"],
  ["DeadCore", "Deadcore"],
  ["Half-Life 2", "Half-Life 2"],
  ["DARK SOULS™ II: Scholar of the First Sin", "Dark Souls II: Scholar of the First Sin"],
  ["Dark Fall 2: Lights Out", "Dark Fall II: Lights Out"],
  ["CUSTOM ORDER MAID 3D2 It's a Night Magic", "Custom Order Maid 3D2: It's a Night Magic"],
  ["DOOM Eternal", "Doom Eternal"],
  ["Feeding Frenzy 2: Shipwreck Showdown Deluxe", "Feeding Frenzy 2: Shipwreck Showdown"],
  ["Godfather II", "Godfather 2"],
  ["GTR 2 - FIA GT Racing Game", "GTR 2 – FIA GT Racing Game"],
  ["Hacker Evolution - Untold", "Hacker Evolution: Untold"],
  ["Heroes of Might & Magic V", "Heroes of Might and Magic V"],
  ["Holy Potatoes! We’re in Space?!", "Holy Potatoes! We're in Space?!"],
  ["ibb & obb", "Ibb and Obb"],
  ["Iggle Pop! Deluxe", "Iggle Pop!"],
  ["James Cameron’s Avatar™: The Game", "James Cameron's Avatar: The Game"]
]

pairs_that_should_not_match = [
  ["FORCED 2: The Rush", "Forced: Showdown"],
  ["Heartomics 2", "Nokori"],
  ["Hector: Badge of Carnage – Episode 3: Beyond Reasonable Doom", "Hector: Badge of Carnage"]
]

pass_count = 0
fail_count = 0

pairs_that_should_match.each do |pair|
  same_name = games_have_same_name?(pair[0], pair[1])
  puts "#{same_name ? Rainbow("PASS").green.bold : Rainbow("FAIL").red.bold}: #{pair[0]} == #{pair[1]}"

  pass_count += 1 if same_name
  fail_count += 1 if !same_name
end

pairs_that_should_not_match.each do |pair|
  same_name = games_have_same_name?(pair[0], pair[1])
  puts "#{same_name ? Rainbow("FAIL").red.bold : Rainbow("PASS").green.bold}: #{pair[0]} != #{pair[1]}"

  pass_count += 1 if !same_name
  fail_count += 1 if same_name
end

puts "#{pass_count} PASSED | #{fail_count} FAILED"
