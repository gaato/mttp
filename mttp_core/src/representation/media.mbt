///|
/// Accept negotiation result: a zero-based offer index or no acceptable offer.
#non_exhaustive
#derive(Eq, Debug)
pub(all) enum MediaChoice {
  Offer(Int32)
  Unacceptable
}

///|
/// Compares media negotiation results.
pub extend MediaChoice with Eq::{equal, not_equal}

///|
/// Formats a media negotiation result for debugging.
pub extend MediaChoice with @debug.Debug::{to_repr}

///|
fn invalid(detail : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Invalid, phase=Head, detail~)
}

///|
fn quality(value : StringView) -> Int32 raise @mttp_core.TransportError {
  guard value.length() > 0 && (value[0] == '0' || value[0] == '1') else {
    raise invalid("invalid Accept weight")
  }
  let whole = if value[0] == '1' { 1000 } else { 0 }
  if value.length() == 1 {
    return whole
  }
  if value[1] != '.' || value.length() > 5 {
    raise invalid("invalid Accept weight")
  }
  let mut result = whole
  let mut place = 100
  for c in value[2:] {
    if c < '0' || c > '9' || (whole == 1000 && c != '0') {
      raise invalid("invalid Accept weight")
    }
    result += (c.to_int() - 48) * place
    place /= 10
  }
  result
}

///|
fn pieces(
  value : StringView,
  separator : UInt16,
) -> Array[StringView] raise @mttp_core.TransportError {
  let out = []
  let mut quoted = false
  let mut escaped = false
  let mut start = 0
  for i in 0..<value.length() {
    let c = value[i]
    if escaped {
      escaped = false
    } else if quoted && c == '\\' {
      escaped = true
    } else if c == '"' {
      quoted = !quoted
    } else if !quoted && c == separator {
      out.push(value[start:i].trim(chars=" \t"))
      start = i + 1
    }
  }
  if quoted || escaped {
    raise invalid("unclosed Accept parameter")
  }
  out.push(value[start:].trim(chars=" \t"))
  out
}

///|
fn token(value : StringView) -> Bool {
  !value.is_empty() &&
  value
  .iter()
  .all(c => {
    match c {
      'a'..<='z'
      | 'A'..<='Z'
      | '0'..<='9'
      | '!'
      | '#'
      | '$'
      | '%'
      | '&'
      | '\''
      | '*'
      | '+'
      | '-'
      | '.'
      | '^'
      | '_'
      | '`'
      | '|'
      | '~' => true
      _ => false
    }
  })
}

///|
priv struct Media {
  kind : String
  subtype : String
  parameters : Map[String, String]
  weight : Int32
}

///|
fn parse_media(
  value : StringView,
  accept : Bool,
) -> Media raise @mttp_core.TransportError {
  let parts = pieces(value, ';')
  let name = parts[0].to_owned().to_lower()
  guard name.split("/").collect() is [kind, subtype] &&
    token(kind) &&
    token(subtype) &&
    (kind != "*" || subtype == "*") else {
    raise invalid("invalid media type")
  }
  let parameters : Map[String, String] = Map([])
  let mut weight = 1000
  let mut weighted = false
  for part in parts[1:] {
    guard part.find("=") is Some(equal) else {
      raise invalid("invalid media parameter")
    }
    let key = part[:equal].trim(chars=" \t").to_owned().to_lower()
    let raw = part[equal + 1:].trim(chars=" \t")
    guard token(key[:]) && !raw.is_empty() else {
      raise invalid("invalid media parameter")
    }
    if accept && key == "q" {
      if weighted {
        raise invalid("duplicate Accept weight")
      }
      weight = quality(raw)
      weighted = true
    } else {
      let value = if raw.has_prefix("\"") &&
        raw.has_suffix("\"") &&
        raw.length() >= 2 {
        let b = StringBuilder()
        let mut escape = false
        for c in raw[1:raw.length() - 1] {
          if escape {
            b.write_char(c)
            escape = false
          } else if c == '\\' {
            escape = true
          } else {
            b.write_char(c)
          }
        }
        b.to_string()
      } else {
        guard token(raw) else { raise invalid("invalid media parameter") }
        raw.to_owned()
      }
      if !weighted {
        parameters[key] = if key == "charset" {
          value.to_lower()
        } else {
          value
        }
      }
    }
  }
  { kind: kind.to_owned(), subtype: subtype.to_owned(), parameters, weight, }
}

///|
/// Negotiates Accept against offered media types. The most specific matching
/// range determines each offer's weight, then weight, specificity and offer
/// order break ties. Missing Accept accepts all; empty Accept accepts none.
/// Field values are limited to 16 KiB UTF-8 and 128 nonempty items.
pub fn negotiate_media(
  headers : @mttp_core.Headers,
  offers : ArrayView[String],
) -> MediaChoice raise @mttp_core.TransportError {
  let fields = headers.get_all("accept")
  if fields.is_empty() {
    return if offers.is_empty() { Unacceptable } else { Offer(0) }
  }
  let ranges : Array[Media] = []
  let mut bytes = 0
  for field in fields {
    if field.length() > 16384 - bytes {
      raise invalid("Accept exceeds 16 KiB")
    }
    bytes += @mttp_core.encode_utf8(field).length()
    if bytes > 16384 {
      raise invalid("Accept exceeds 16 KiB")
    }
    for item in pieces(field[:], ',') {
      if item.is_empty() {
        continue
      }
      if ranges.length() == 128 {
        raise invalid("Accept exceeds 128 items")
      }
      ranges.push(parse_media(item, true))
    }
  }
  let mut best = Unacceptable
  let mut best_q = 0
  let mut best_specificity = -1
  for i, offer in offers {
    let offer = parse_media(offer[:], false)
    let mut specificity = -1
    let mut weight = 0
    for range in ranges {
      if (range.kind == "*" || range.kind == offer.kind) &&
        (range.subtype == "*" || range.subtype == offer.subtype) &&
        range.parameters
        .iter()
        .all(pair => offer.parameters.get(pair.0) == Some(pair.1)) {
        let score = (if range.kind == "*" {
            0
          } else if range.subtype == "*" {
            1
          } else {
            2
          }) *
          16385 +
          range.parameters.length()
        if score > specificity {
          specificity = score
          weight = range.weight
        } else if score == specificity {
          weight = weight.min(range.weight)
        }
      }
    }
    if weight > best_q ||
      (weight > 0 && weight == best_q && specificity > best_specificity) {
      best = Offer(i)
      best_q = weight
      best_specificity = specificity
    }
  }
  best
}
