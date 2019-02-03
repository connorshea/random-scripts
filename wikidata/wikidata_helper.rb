module WikidataHelper
  require "addressable/template"
  require "open-uri"
  require "json"

  def api_test
    query_options = [:format, :props, :languages, :ids]
    query_options_string = query_options.join(',')

    template = Addressable::Template.new(
      "https://{host}{/segments*}{?#{query_options_string}}"
    )

    uri = Addressable::URI.parse(
      "https://www.wikidata.org/w/api.php?format=json"
    )

    puts uri.inspect
    puts template.inspect

    parsed_uri = template.extract(uri)

    puts parsed_uri.inspect
  end

  #
  # Make an API call.
  #
  # @param [String] action The action to perform, see https://www.wikidata.org/w/api.php?action=help&modules=main
  # @param [String] ids Wikidata IDs, e.g. 'Q123' or 'P123'
  # @param [String] props Property type
  # @param [<Type>] languages <description>
  #
  # @return [<Type>] <description>
  #
  def api(action: nil, ids: nil, props: nil, languages: 'en')
    query_options = [
      :format,
      :action,
      :props,
      :languages,
      :ids,
      :sitelinks
    ]
    query_options_string = query_options.join(',')
    
    template = Addressable::Template.new("https://www.wikidata.org/w/api.php{?#{query_options_string}}")
    template = template.expand({
      'action': action,
      'format': 'json',
      'ids': ids,
      'languages': languages,
      'props': props
    })

    puts template
    api_uri = URI.parse(template.to_s)

    response = JSON.load(open(api_uri))

    if response['success']
      return response['entities']["#{ids}"]
    else
      return nil
    end
  end

  def get_all_entities(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids
    )
  end

  def get_claims(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids,
      props: 'claims'
    )
  end

  def get_descriptions(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids,
      props: 'descriptions'
    )
  end

  def get_datatype(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids,
      props: 'datatype'
    )
  end

  def get_aliases(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids,
      props: 'aliases'
    )
  end

  def get_labels(ids:)
    response = api(
      action: 'wbgetentities',
      ids: ids,
      props: 'labels',
      languages: nil
    )

    puts response.inspect
  end

  #
  # Get sitelinks for a given Wikidata item.
  #
  # @param [String] ids Wikidata IDs, e.g. 'Q123' or 'P123'
  #
  # @return [Hash] Returns a hash of sitelinks.
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
end

include WikidataHelper

WikidataHelper.get_claims(ids: 'Q42')
WikidataHelper.get_descriptions(ids: 'Q42')
WikidataHelper.get_datatype(ids: 'P42')
WikidataHelper.get_aliases(ids: 'Q42')
WikidataHelper.get_labels(ids: 'Q42')
WikidataHelper.get_sitelinks(ids: 'Q42')
