require 'net/https'
require 'json'

def igdb_api_request(body:, endpoint: 'games')
  http = Net::HTTP.new('api-v3.igdb.com',443)
  http.use_ssl = true
  request = Net::HTTP::Post.new(URI("https://api-v3.igdb.com/#{endpoint}"), {'user-key' => ENV['IGDB_API_KEY']})
  request.body = body
  body = http.request(request).body

  return body
end

body = igdb_api_request(endpoint: 'games', body: 'fields name,slug,url,websites;')

games = JSON.parse(body)

puts JSON.pretty_generate(games)

games_with_websites = []

games.each do |game|
  next if game['websites'].nil?

  games_with_websites << {
    id: game['id'],
    name: game['name'],
    slug: game['slug'],
    websites: game['websites']
  }
end

puts games_with_websites.inspect

website_categories = {
  1 => :official,
  2 => :wikia,
  3 => :wikipedia,
  4 => :facebook,
  5 => :twitter,
  6 => :twitch,
  8 => :instagram,
  9 => :youtube,
  10 => :iphone,
  11 => :ipad,
  12 => :android,
  13 => :steam,
  14 => :reddit,
  15 => :itch,
  16 => :epicgames,
  17 => :gog
}

games_with_websites.each do |game|
  game[:websites]&.each do |website_id|
    response = igdb_api_request(endpoint: 'websites', body: "fields category,game,trusted,url; where id = #{website_id};")

    puts "RESPONSE"
    website = JSON.parse(response)
    website = website[0]

    puts website.inspect
    puts "#{game[:slug]}: #{website['url']}" if website["category"] == 13
  end
end
