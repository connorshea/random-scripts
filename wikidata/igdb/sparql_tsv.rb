# frozen_string_literal: true

# Helpers for reading SPARQL TSV results and writing QuickStatements.


# Reads a SPARQL TSV result (QLever or WDQS) into an array of hashes keyed by
# variable name without the "?".
def read_sparql_tsv(path)
  lines = File.readlines(path, chomp: true)
  abort "#{path} doesn't look like a SPARQL TSV result:\n#{lines.first(5).join("\n")}" unless lines.first&.start_with?('?')

  # QLever reports an error during export by appending it to the truncated
  # result, since the HTTP status has already been sent.
  if (error_line = lines.find { |l| l.include?('An error has occurred while exporting the query result') })
    abort "#{path} is truncated, the query failed partway through:\n#{error_line}"
  end

  header = lines.shift.split("\t").map { |h| h.delete_prefix('?') }
  lines.reject(&:empty?).map { |line| header.zip(line.split("\t", -1)).to_h }
end

# "<http://www.wikidata.org/entity/Q123>" -> "Q123"
def qid_from(value)
  value.to_s[/Q\d+(?=>?\z)/]
end

# "\"Some \\\"name\\\"\"@en" -> "Some \"name\""; bare values come back as-is.
def literal_from(value)
  value = value.to_s
  match = value.match(/\A"(.*)"(?:@[\w-]+|\^\^.+)?\z/m)
  return value if match.nil?

  match[1].gsub(/\\(.)/) do
    case Regexp.last_match(1)
    when 't' then "\t"
    when 'n' then "\n"
    when 'r' then "\r"
    else Regexp.last_match(1)
    end
  end
end

def tsv_row(values)
  values.map { |v| v.to_s.gsub(/\s/, ' ') }.join("\t")
end
