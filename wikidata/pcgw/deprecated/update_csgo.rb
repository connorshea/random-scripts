# Simple script to update Counter-Strike: Global Offensive with the PCGamingWiki ID claim.
require 'mediawiki_api'
require "mediawiki_api/wikidata/wikidata_client"

wikidata_client = MediawikiApi::Wikidata::WikidataClient.new "https://www.wikidata.org/w/api.php"
wikidata_client.log_in "Nicereddy", ENV["WIKIDATA_PASSSWORD"]
wikidata_client.create_claim "Q842146", "value", "P6337", '"Counter-Strike:_Global_Offensive"'
