// RFC 9842's server side: compressing a response with the dictionary a
// request names, and marking a response as a dictionary.

///|
/// The dictionary coding `headers` accept and its weight in thousandths,
/// or None: `dcz` or `dcb` with a weight above zero in Accept-Encoding, the
/// higher weight first and `dcz` at equal weights. Malformed weights accept
/// neither: `compress` answers them.
fn dictionary_choice(headers : @mttp_core.Headers) -> (Coding, Int32)? {
  let mut dcb = 0
  let mut dcz = 0
  let mut seen_dcb = false
  let mut seen_dcz = false
  for field in headers.get_all("accept-encoding") {
    for entry in field.split(",") {
      let parts = entry.trim(chars=" \t").split(";").collect()
      guard parts.length() >= 1 else { continue }
      let token = parts[0].trim(chars=" \t").to_owned().to_lower()
      guard token == "dcb" || token == "dcz" else { continue }
      let weight = match parts {
        [_] => 1000
        [_, parameter] => {
          let parameter = parameter.trim(chars=" \t").to_owned().to_lower()
          guard parameter.has_prefix("q=") else { return None }
          quality(parameter[2:]) catch {
            _ => return None
          }
        }
        _ => return None
      }
      // A repeated name takes its lowest weight, as negotiate_encoding does.
      if token == "dcb" {
        dcb = if seen_dcb { dcb.min(weight) } else { weight }
        seen_dcb = true
      } else {
        dcz = if seen_dcz { dcz.min(weight) } else { weight }
        seen_dcz = true
      }
    }
  }
  if dcz > 0 && dcz >= dcb {
    Some((Dcz, dcz))
  } else if dcb > 0 {
    Some((Dcb, dcb))
  } else {
    None
  }
}

///|
/// The dictionary of `dictionaries` the request's Available-Dictionary names
/// by its SHA-256, if any.
fn offered_dictionary(
  headers : @mttp_core.Headers,
  dictionaries : ArrayView[ServerDictionary],
) -> ServerDictionary? {
  guard @sf.parse_item(headers.get_all("available-dictionary"))
    is Some({ value: Bytes(hash), .. }) else {
    return None
  }
  for d in dictionaries {
    if d.hash == hash {
      return Some(d)
    }
  }
  None
}

///|
/// RFC 9842 section 9.3.3: whether a dictionary may compress `response` to a
/// request with `request_headers`. A cross-origin request's response may be
/// read by the requesting page only through CORS, and a dictionary must not
/// make it readable otherwise: without Sec-Fetch-Site, or same-origin, or a
/// navigation, it may; a CORS request only when the response allows its
/// Origin; anything else may not.
pub fn dictionary_allowed(
  request_headers : @mttp_core.Headers,
  response_headers : @mttp_core.Headers,
) -> Bool {
  // Repeated field lines are one value joined by commas (RFC 9110 section
  // 5.2): two Access-Control-Allow-Origin lines match no origin.
  let field = (headers : @mttp_core.Headers, name : String) => {
    let lines = headers.get_all(name)
    if lines.is_empty() {
      None
    } else {
      Some(lines.join(", ").trim(chars=" \t").to_owned())
    }
  }
  guard field(request_headers, "sec-fetch-site") is Some(site) else {
    return true
  }
  // The values are compared as written, as the section's algorithm does.
  if site == "same-origin" {
    return true
  }
  guard field(request_headers, "sec-fetch-mode") is Some(mode) else {
    return true
  }
  match mode {
    "navigate" | "same-origin" => true
    "cors" => {
      guard field(response_headers, "access-control-allow-origin")
        is Some(allow) &&
        field(request_headers, "origin") is Some(origin) else {
        return false
      }
      allow == "*" || allow == origin
    }
    _ => false
  }
}

///|
/// `compress`, and with RFC 9842's dictionaries: a request whose
/// Available-Dictionary names one of `dictionaries` and whose
/// Accept-Encoding takes `dcz` or `dcb` at least as much as identity and
/// every other coding gets the response coded with that dictionary (`dcz`
/// at equal weights), when it came over a secure context, as section 8
/// requires, and section 9.3.3 allows it (`dictionary_allowed`).
///
/// `secure` says whether a request came over TLS. The request's URL cannot
/// tell: a client may write an `https` target on a cleartext connection.
/// Pass `_ => true` for a server that listens only over TLS, or check a
/// header a trusted proxy that ends TLS sets, such as its X-Forwarded-Proto.
///
/// Every response it may code carries `Vary: Accept-Encoding,
/// Available-Dictionary`, as section 6.2 asks, so a cache keeps the
/// dictionary-coded one apart; one whose coding the section 9.3.3 check
/// decided also varies on Sec-Fetch-Site, Sec-Fetch-Mode and Origin, so a
/// cache cannot hand it to a request the check would have refused. Other
/// requests, and responses a dictionary may not code, are compressed as
/// `compress` does. A known body smaller than `min_bytes` is left as it is.
pub fn dictionary_compress(
  handler : @mttp_core.Handler,
  dictionaries : Array[ServerDictionary],
  min_bytes~ : Int32 = 1024,
  secure~ : (@mttp_core.Request) -> Bool,
) -> @mttp_core.Handler {
  request => {
    let response = handler(request)
    let mut vary = ["Available-Dictionary"]
    let candidate = match
      (
        dictionary_choice(request.headers),
        offered_dictionary(request.headers, dictionaries),
      ) {
      (Some(choice), Some(dictionary)) if may_encode(request, response) &&
        secure(request) => {
        // The security check reads these: a cache must key on them too.
        vary = [..vary, "Sec-Fetch-Site", "Sec-Fetch-Mode", "Origin"]
        if dictionary_allowed(request.headers, response.headers) {
          Some((choice, dictionary))
        } else {
          None
        }
      }
      _ => None
    }
    guard candidate is Some(((coding, weight), dictionary)) else {
      return compress_response(request, response, min_bytes, vary)
    }
    // The client's preference across every coding: a plain coding or
    // identity it weighs above the dictionary coding wins. A malformed
    // Accept-Encoding is refused, as compress refuses it.
    let weights = encoding_weights(request.headers) catch {
      _ => {
        response.close()
        return @mttp_core.Response::new(400)
      }
    }
    // Accept-Encoding named dcb or dcz, so it is there to weigh.
    let (plain, identity) = weights
      .map(w => {
        let wildcard = w[4].unwrap_or(0)
        let best = [0, 1, 2, 5].fold(init=0, (m, i) => {
          m.max(w[i].unwrap_or(wildcard))
        })
        (best, w[3])
      })
      .unwrap_or((0, None))
    if weight < plain || (identity is Some(i) && weight < i) {
      return compress_response(request, response, min_bytes, vary)
    }
    let identity_ok = identity != Some(0) &&
      !(identity is None && weights.bind(w => w[4]) == Some(0))
    let headers = add_vary(response.headers, ["Accept-Encoding", ..vary])
    if identity_ok &&
      response.body.length() is Some(length) &&
      length < min_bytes.max(0).to_int64() {
      return { ..response, headers, }
    }
    encoded_response(response, headers, coding, Some(dictionary))
  }
}

///|
/// `response` marked as a dictionary for the requests `match_` matches
/// (RFC 9842 section 2.1), for `match_dest` destinations and with `id`
/// echoed back in Dictionary-ID. A client keeps it only while it is fresh,
/// or stale within its stale-while-revalidate window, so give it a
/// Cache-Control with a lifetime. Raises
/// `Invalid` for a `match_` or `id` a Structured Field cannot carry or a
/// client would not read (over 1024 characters).
pub fn use_as_dictionary(
  response : @mttp_core.Response,
  match_~ : String,
  match_dest~ : Array[String] = [],
  id~ : String = "",
) -> @mttp_core.Response raise @mttp_core.TransportError {
  let directive : @dictionary.UseAsDictionary = { match_, match_dest, id, }
  guard directive.to_header() is Some(value) else {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Head,
      detail="Use-As-Dictionary cannot carry this match or id",
    )
  }
  { ..response, headers: response.headers.set("use-as-dictionary", value), }
}
