module WikidataHelper
  require "addressable/template"
  require "open-uri"
  require "json"

  #
  # Make an API call.
  #
  # @param [String] action The action to perform, see https://www.wikidata.org/w/api.php?action=help&modules=main
  # @param [String] ids Wikidata IDs, e.g. 'Q123' or 'P123'
  # @param [String] props Property type
  # @param [String] languages Language code
  # @param [String] entity Wikidata entity ID, e.g. 'Q123'
  #
  # @return [Hash] Ruby hash form of the Wikidata JSON Response.
  #
  def api(action: nil, ids: nil, props: nil, languages: 'en', entity: nil, property: nil)
    query_options = [
      :format,
      :action,
      :props,
      :languages,
      :ids,
      :sitelinks,
      :entity,
      :property
    ]
    query_options_string = query_options.join(',')
    
    template = Addressable::Template.new("https://www.wikidata.org/w/api.php{?#{query_options_string}}")
    template = template.expand({
      'action': action,
      'format': 'json',
      'ids': ids,
      'languages': languages,
      'props': props,
      'entity': entity,
      'property': property
    })

    puts template if ENV['DEBUG']
    api_uri = URI.parse(template.to_s)

    response = JSON.load(open(api_uri))

    if response['success'] && action == 'wbgetentities'
      return response['entities']
    elsif action == 'wbgetclaims'
      return response['claims']
    else
      return nil
    end
  end

  def get_all_entities(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids
    )

    return response
  end

  def get_descriptions(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids,
      props: 'descriptions'
    )

    return response
  end

  def get_datatype(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids,
      props: 'datatype'
    )

    return response
  end

  def get_aliases(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids,
      props: 'aliases'
    )

    return response
  end

  #
  # Get labels ('names') of the given items
  #
  # @param [String, Array<String>] ids Wikidata IDs, e.g. 'Q123' or ['Q123', 'Q124']
  # @param [String, Array<String>] languages A country code or array of country codes, e.g. 'en' or ['en', 'es']
  #
  # @return [Hash] Hash of labels in the listed languages.
  #
  def get_labels(ids:, languages: nil)
    if ids.is_a?(Array)
      ids = ids.join('|')
    end

    if languages.is_a?(Array)
      languages = languages.join('|')
    end

    response = api(
      action: 'wbgetentities',
      ids: ids,
      props: 'labels',
      languages: languages
    )

    return response
  end
  alias_method :get_names, :get_labels

  #
  # Get sitelinks for a given Wikidata item.
  #
  # @param [String] ids Wikidata IDs, e.g. 'Q123' or 'P123'
  #
  # @return [Hash] Returns a hash of sitelinks.
  #
  # {
  #   "afwiki"=>{
  #     "site"=>"afwiki",
  #     "title"=>"Douglas Adams",
  #     "badges"=>[]
  #   },
  #   "bswiki"=>{
  #     "site"=>"bswiki",
  #     "title"=>"Douglas Adams",
  #     "badges"=>[]
  #   }
  # }
  #
  def get_sitelinks(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids,
      props: 'sitelinks'
    )

    sitelinks = []
    response['sitelinks'].each { |sitelink| sitelinks << sitelink[1] }

    return sitelinks
  end

  #
  # Get claims about an Wikidata entity.
  # https://www.wikidata.org/w/api.php?action=help&modules=wbgetclaims
  #
  # @param [string] entity Wikidata entity ID, e.g. 'Q123'
  # @param [string] property Wikidata property ID, e.g. 'P123'
  #
  # @return [Hash] Returns a hash with the properties of the entity.
  #
  def get_claims(entity:, property: nil)
    response = api(
      action: 'wbgetclaims',
      entity: entity,
      languages: nil,
      property: property
    )

    return response
  end
end

include WikidataHelper

def prettify(input)
  return JSON.pretty_generate(input)
end

def claims_helper(game, property)
  return WikidataHelper.get_claims(entity: game, property: PROPERTIES[property])
end

# Takes an array of ids and returns an array of hashes, each with an id and English name.
def get_english_names(ids)
  names = WikidataHelper.get_names(ids: ids, languages: 'en')
  name_hashes = []

  names.each do |prop_id, name|
    name_hashes << { id: prop_id, name: name['labels']['en']['value'] }
  end

  return name_hashes
end

# Convenience method for returning just one name.
def get_english_name(id)
  names = get_english_names(id)
  return names.first
end

def get_entity_properties(id)
  claims = WikidataHelper.get_claims(entity: id)
  return claims.keys
end

# Return an array of an entity's properties and the English names for each.
def pretty_get_entity_properties(id)
  keys = get_entity_properties(id)
  keys.sort! { |a, b| a[1..-1].to_i <=> b[1..-1].to_i }
  keys_hash = {}

  names_hashes = get_english_names(keys)

  return names_hashes
end

#
# Prints a list of an entity's properties.
#
# @param [String] id The Wikidata identifier, e.g. 'Q123' or 'P123'.
#
# @return [void]
#
def print_entity_properties(id)
  properties = pretty_get_entity_properties(id)
  properties.each do |property|
    puts "#{property[:id]}: #{property[:name]}"
  end
end

def get_genres(id)
  claims = claims_helper(id, :genres)
  genres = claims[PROPERTIES[:genres]]
  genre_ids = []
  genres.each do |genre|
    genre_id = genre['mainsnak']['datavalue']['value']['id']
    puts 'qualifiers!' unless genre['qualifiers'].nil?
    genre_ids << genre_id
  end
  
  return genre_ids
end

# WikidataHelper.get_claims(entity: 'Q4200', property: 'P31')
# WikidataHelper.get_descriptions(ids: 'Q42')
# WikidataHelper.get_datatype(ids: 'P42')
# WikidataHelper.get_aliases(ids: 'Q42')
# WikidataHelper.get_labels(ids: 'Q42')
# WikidataHelper.get_sitelinks(ids: 'Q42')

PROPERTIES = {
  publishers: 'P123',
  platforms: 'P400',
  developers: 'P178',
  genres: 'P136',
  publication_dates: 'P577'
}

games = {
  'Half-Life': 'Q279744',
  'Call of Duty 4: Modern Warfare': 'Q76255',
  'Half-Life 2': 'Q193581',
  'Half-Life 2: Episode One': 'Q18951',
  'Half-Life 2: Episode Two': 'Q553308',
  'Portal 2': 'Q279446',
  "Kirby's Epic Yarn": 'Q1361363',
  'Doom': 'Q513867'
}

half_life = {}

half_life['name'] = get_english_name(games['Half-Life'.to_sym])

half_life['genres'] = get_genres(games['Half-Life'.to_sym])

half_life_developers = claims_helper(games['Half-Life'.to_sym], :developers)
# puts prettify(half_life_developers)

half_life['developers'] = half_life_developers[PROPERTIES[:developers]]

5.times { puts }
puts prettify(half_life)

# print_entity_properties(games['Half-Life'.to_sym])
