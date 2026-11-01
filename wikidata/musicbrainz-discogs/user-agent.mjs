// User agent for requests to Wikidata and QLever. Wikimedia's user-agent policy asks for contact
// details, so the scripts read an email address from the CONTACT_EMAIL environment variable.
const email = process.env.CONTACT_EMAIL;
if (!email) {
  console.error("Set CONTACT_EMAIL to an email address to include in the User-Agent header.");
  process.exit(1);
}
export const UA = `random-scripts-musicbrainz-discogs/1.0 (${email})`;
