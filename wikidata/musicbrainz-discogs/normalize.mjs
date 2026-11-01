// Name normalization shared by every name comparison in this folder.
//
// Ignores case, quote and dash styles, extra spaces, accents on Latin letters ("Chloë" == "Chloe"),
// "and" vs "&", and punctuation.
// Only the combining diacritical marks block (U+0300–U+036F) is stripped, so marks that change the letter
// in other scripts, like the Japanese voicing marks in ガ (U+3099), are kept.

const LETTERS = { ø: "o", Ø: "O", ł: "l", Ł: "L", đ: "d", Đ: "D", ß: "ss", æ: "ae", Æ: "AE", œ: "oe", Œ: "OE" };

const base = (s) =>
  s
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[øØłŁđĐßæÆœŒ]/g, (c) => LETTERS[c])
    .normalize("NFC")
    .replace(/[‘’ʼ`´]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[‐-―]/g, "-")
    .replace(/\s+/g, " ")
    .trim()
    .toLocaleLowerCase("en");

// Also treats "and" and "&" as the same, and punctuation and hyphens as spaces:
// "Bobs and LoLo" == "Bobs & Lolo", "Jo-Ann Pickens" == "Jo Ann Pickens", "BIG|BRAVE" == "Big Brave".
// A name that is nothing but punctuation (the band "!!!") keeps its punctuation, so it can't match an empty string.
export const normalize = (s) => {
  const b = base(s);
  const loose = b
    .replace(/(^| )and( |$)/g, "$1&$2")
    .replace(/[.\-|/\\,:;!?'"()\[\]~～〜·•*+]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return loose || b;
};

// Discogs disambiguates identical names with a numbered suffix, e.g. "John Smith (3)"
export const stripDiscogsSuffix = (s) => s.replace(/ \(\d+\)$/, "");
