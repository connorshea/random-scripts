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

switch_titles_with_eshop_ids = JSON.parse(File.read('wikidata/eshop/switch-titles-with-eshop-ids.json')) if File.exist?('wikidata/eshop/switch-titles-with-eshop-ids.json')

switch_titles_with_eshop_ids ||= []

progress_bar = ProgressBar.create(
  total: switch_title_dump.count,
  format: "\e[0;32m%c/%C |%b>%i| %e\e[0m"
)

added_count = 0

switch_title_ids_already_dumped = switch_titles_with_eshop_ids.map { |hash| hash['switch_title_id'] }

switch_title_dump.each do |switch_title|
  progress_bar.log("Evaluating #{switch_title['name']}...")

  # Skip if we already have this record in the list.
  if switch_title_ids_already_dumped.include?(switch_title['external_id'])
    progress_bar.log 'This has already been added. Skipping...'
    progress_bar.increment
    next
  end

  # Only do 1000 at a time.
  if added_count > 1000
    progress_bar.increment
    next
  end
  added_count += 1

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

# Make a bell noise when the script ends so it can be re-run.
3.times { system("tput bel") }

progress_bar.finish unless progress_bar.finished?

File.write('wikidata/eshop/switch-titles-with-eshop-ids.json', JSON.pretty_generate(switch_titles_with_eshop_ids))
