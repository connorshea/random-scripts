# frozen_string_literal: true

# Video game name comparison, shared by the QuickStatements generators.

require 'rubygems/text'

LEVENSHTEIN = Class.new.extend(Gem::Text).method(:levenshtein_distance)

# Lowercase, NFKC-normalize, drop trademark signs and a trailing
# "(video game)", treat "&" as "and", then drop everything that isn't a
# letter or digit.
def normalize_name(name)
  # Trademark signs go first, NFKC would turn ™ into "TM".
  name.to_s.gsub(/[™®©]/, '').unicode_normalize(:nfkc).downcase
      .sub(/\s*\((?:\d{4} )?video game\)\z/, '')
      .gsub('&', ' and ')
      .gsub(/[^\p{L}\p{N}]+/, '')
end

# True if any Wikidata name matches the other name, exactly after
# normalizing, or within a Levenshtein distance of 2 for names of 8 or more
# characters.
def names_match?(wikidata_names, other_name)
  wd = wikidata_names.map { |n| normalize_name(n) }.reject(&:empty?).uniq
  other = normalize_name(other_name)
  return false if other.empty?
  return true if wd.include?(other)

  wd.any? do |name|
    [name.length, other.length].min >= 8 && (name.length - other.length).abs <= 2 && LEVENSHTEIN.call(name, other) <= 2
  end
end
