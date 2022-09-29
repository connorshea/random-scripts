#
# Using switch-titles.json, create a `switch-titles-with-eshop-ids.json`.
# We'll have a secondary script to 
#
# switch-titles.json comes from the "Download" link on the Nintendo Switch Titles Mix'n'match catalogue.
# https://mix-n-match.toolforge.org/#/catalog/5481

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'

  gem 'httparty', '~> 0.20.0'
  gem 'ruby-progressbar', '~> 1.10'
end

require 'json'
require 'httparty'

switch_title_dump = JSON.parse(File.read('wikidata/eshop/switch-titles.json'))

switch_titles_with_eshop_ids = []

progress_bar = ProgressBar.create(
  total: switch_title_dump.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

switch_title_dump.each  do |switch_title|
  progress_bar.log("Evaluating #{switch_title['name']}...")

  # Follow the redirects so we can get the final URL that this external URL points to.
  response = HTTParty.head(switch_title['external_url'])
  redirected_uri = response.request.last_uri.to_s

  if redirected_uri.match?(/https:\/\/www\.nintendo\.com\/store\/products\/([\w-]+)\//)
    eshop_id = redirected_uri.match(/https:\/\/www\.nintendo\.com\/store\/products\/([\w-]+)\//)[1]

    if eshop_id.nil?
      progress_bar.log("#{switch_title['external_id']} did not result in a successful redirect. Skipping...")
      progress_bar.increment
      next
    end

    switch_titles_with_eshop_ids << {
      switch_title_id: switch_title['external_id'],
      eshop_id: eshop_id
    }
  else
    progress_bar.log("#{switch_title['external_id']} did not result in a successful redirect. Skipping...")
    progress_bar.increment
    next
  end

  sleep 0.5
  progress_bar.increment
end

progress_bar.finish unless progress_bar.finished?

File.write('wikidata/eshop/switch-titles-with-eshop-ids.json', JSON.pretty_generate(switch_titles_with_eshop_ids))
