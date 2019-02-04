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

def get_properties(id, property)
  claims = claims_helper(id, property)
  properties = claims[PROPERTIES[property]]
  datatype = properties.first['mainsnak']['datatype']

  if datatype == 'wikidata-item'
    return_properties = parse_item_properties(properties)
  elsif datatype == 'time'
    return_properties = parse_time_properties(properties)
  else
    return_properties = parse_item_properties(properties)
  end
  
  return return_properties
end

def parse_item_properties(properties)
  property_ids = []

  properties.each do |property|
    property_id = property['mainsnak']['datavalue']['value']['id']
    unless property['qualifiers'].nil?
      property_ids << { property_id: property_id, qualifiers: parse_item_qualifiers(property['qualifiers']) }
      next
    end
    property_ids << { property_id: property_id }
  end

  return property_ids
end

def parse_time_properties(publication_dates)
  publication_date_times = []

  publication_dates.each do |publication_date|
    publication_date_time = publication_date['mainsnak']['datavalue']['value']['time']
    unless publication_date['qualifiers'].nil?
      publication_date_times << { time: Date.rfc3339(publication_date_time[1..-1]), qualifiers: parse_time_qualifiers(publication_date['qualifiers']) }
      next
    end
    # Wikidata's API outputs dates in the format "+2016-05-13T00:00:00Z"
    # This removes the first character so that Date.rfc3339 can parse it.
    publication_date_times << { time: Date.rfc3339(publication_date_time[1..-1]) }
  end
  
  return publication_date_times
end

def parse_item_qualifiers(qualifiers)
  return_value = {}

  qualifiers.each do |property, qualifiers_for_property|
    platforms = [] if property == PROPERTIES[:platforms]
    qualifiers_for_property.each do |qualifier|
      if property == PROPERTIES[:platforms]
        platforms << qualifier['datavalue']['value']['id']
      else
        puts "MISSED QUALIFIER: #{property}" if QUALIFIER_TYPES[property.to_sym].nil?
      end
    end

    return_value['platforms'] = platforms if property == PROPERTIES[:platforms]
  end

  return return_value
end

def parse_time_qualifiers(qualifiers)
  return_value = {}

  qualifiers.each do |property, qualifiers_for_property|
    # We don't care about place of publication for now.
    next if QUALIFIER_TYPES[property.to_sym] == :place_of_publication
    platforms = [] if property == PROPERTIES[:platforms]
    qualifiers_for_property.each do |qualifier|
      if property == PROPERTIES[:platforms]
        platforms << qualifier['datavalue']['value']['id']
      else
        puts "MISSED QUALIFIER: #{property}" if QUALIFIER_TYPES[property.to_sym].nil?
      end
    end

    return_value['platforms'] = platforms if property == PROPERTIES[:platforms]
  end

  return return_value
end

def get_genres(id)
  return get_properties(id, :genres)
end

def get_developers(id)
  return get_properties(id, :developers)
end

def get_publishers(id)
  return get_properties(id, :publishers)
end

def get_platforms(id)
  return get_properties(id, :platforms)
end

def get_publication_dates(id)
  return get_properties(id, :publication_dates)
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

QUALIFIER_TYPES = {
  P123: :publisher,
  P291: :place_of_publication,
  P361: :part_of,
  P400: :platform
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

games_data = []

games.each do |name, id|
  game = {}

  game.merge!(get_english_name(id))
  game['genres'] = get_genres(id)
  game['developers'] = get_developers(id)
  game['publishers'] = get_publishers(id)
  game['platforms'] = get_platforms(id)
  game['release_dates'] = get_publication_dates(id)

  games_data << game

  # puts prettify(game)
  # print_entity_properties(id)
end

pretty_games_data = prettify(games_data)

# puts pretty_games_data
File.write('wikidata_games_data.json', pretty_games_data)
