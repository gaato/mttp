///|
/// Result of choosing among the encodings this package can produce.
#non_exhaustive
pub(all) enum EncodingChoice {
  Identity
  Encoded(Coding)
  Unacceptable
} derive(Eq, Debug)

///|
/// Compares negotiated encoding choices.
pub extend EncodingChoice with Eq::{equal, not_equal}

///|
/// Formats negotiated encoding choices.
pub extend EncodingChoice with @debug.Debug::{to_repr}

///|
/// Negotiates gzip, deflate and Brotli using RFC 9110 quality weights.
/// Missing or empty Accept-Encoding selects identity. Explicit exclusions
/// override wildcard weights, repeated names use their lowest weight, and
/// ties prefer gzip, deflate, then Brotli. An explicit higher identity weight
/// wins; Unacceptable means identity and every available encoder are refused.
/// At most 16 KiB of field values and 128 nonempty entries are accepted.
pub fn negotiate_encoding(
  headers : @model.Headers,
) -> EncodingChoice raise @model.TransportError {
  let fields = headers.get_all("accept-encoding")
  if fields.is_empty() {
    return Identity
  }
  let weights : FixedArray[Int32?] = FixedArray::make(5, None)
  let mut remaining = 16384
  let mut count = 0
  for field in fields {
    if field.length() > remaining {
      raise invalid_encoding("Accept-Encoding exceeds 16 KiB")
    }
    remaining -= @utf8.encode(field).length()
    if remaining < 0 {
      raise invalid_encoding("Accept-Encoding exceeds 16 KiB")
    }
    for entry in field.split(",") {
      let entry = entry.trim(chars=" \t")
      if entry.is_empty() {
        continue
      }
      count += 1
      if count > 128 {
        raise invalid_encoding("Accept-Encoding exceeds 128 entries")
      }
      let parts = entry.split(";").collect()
      let token = parts[0].trim(chars=" \t").to_owned().to_lower()
      let weight = match parts {
        [_] => 1000
        [_, parameter] => {
          let parameter = parameter.trim(chars=" \t").to_owned().to_lower()
          guard parameter.has_prefix("q=") else {
            raise invalid_encoding("invalid encoding weight")
          }
          quality(parameter[2:])
        }
        _ => raise invalid_encoding("invalid encoding parameters")
      }
      let index = match token {
        "gzip" | "x-gzip" => Some(0)
        "deflate" => Some(1)
        "br" => Some(2)
        "identity" => Some(3)
        "*" => Some(4)
        _ => None
      }
      if index is Some(index) {
        weights[index] = Some(weights[index].unwrap_or(weight).min(weight))
      }
    }
  }
  let wildcard = weights[4].unwrap_or(0)
  let mut best : Coding? = None
  let mut score = 0
  for index, coding in [Gzip, Deflate, Brotli] {
    let weight = weights[index].unwrap_or(wildcard)
    if weight > score {
      best = Some(coding)
      score = weight
    }
  }
  if weights[3] is Some(identity) && identity > score {
    return Identity
  }
  if best is Some(coding) {
    return Encoded(coding)
  }
  if weights[3] == Some(0) || (weights[3] is None && weights[4] == Some(0)) {
    Unacceptable
  } else {
    Identity
  }
}

///|
fn quality(value : StringView) -> Int32 raise @model.TransportError {
  guard value.length() > 0 && (value[0] == '0' || value[0] == '1') else {
    raise invalid_encoding("invalid encoding weight")
  }
  let whole = if value[0] == '1' { 1000 } else { 0 }
  if value.length() == 1 {
    return whole
  }
  if value[1] != '.' || value.length() > 5 {
    raise invalid_encoding("invalid encoding weight")
  }
  let mut result = whole
  let mut place = 100
  for char in value[2:] {
    if char < '0' || char > '9' || (whole == 1000 && char != '0') {
      raise invalid_encoding("invalid encoding weight")
    }
    result += (char.to_int() - 48) * place
    place /= 10
  }
  result
}

///|
fn invalid_encoding(detail : String) -> @model.TransportError {
  @model.TransportError(kind=Invalid, phase=Head, detail~)
}
