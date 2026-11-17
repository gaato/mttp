///|
/// Negotiates zstd, Brotli, gzip or deflate for a response, preferring them
/// in that order at equal weights. Known bodies smaller
/// than min_bytes (default 1024, negatives clamp to zero) are passed through;
/// unknown-length streams are compressed without prefetching. Every input
/// chunk is sync-flushed and output slices are at most 64 KiB. Skips HEAD,
/// bodyless statuses, Range/206/Content-Range and already encoded responses.
/// Invalid negotiation returns 400; refusal of every encoding returns 406.
pub fn compress(
  handler : @mttp_core.Handler,
  min_bytes~ : Int32 = 1024,
) -> @mttp_core.Handler {
  request => compress_response(request, handler(request), min_bytes, [])
}

///|
/// Whether `response` to `request` may be given a content coding at all:
/// it has a body, is not a range, is not `no-transform`, and is not coded.
fn may_encode(
  request : @mttp_core.Request,
  response : @mttp_core.Response,
) -> Bool {
  has_body(request.meth.to_string(), response.status) &&
  !request.headers.contains("range") &&
  response.status != 206 &&
  !response.headers.contains("content-range") &&
  !response.headers
  .get_all("cache-control")
  .join(",")
  .split(",")
  .any(token => token.trim().to_owned().to_lower() == "no-transform") &&
  !response.headers.contains("content-encoding")
}

///|
/// `headers` with each of `names` in Vary, unless it is there or Vary is `*`.
fn add_vary(
  headers : @mttp_core.Headers,
  names : Array[String],
) -> @mttp_core.Headers {
  let present = headers
    .get_all("vary")
    .join(",")
    .split(",")
    .map(token => token.trim().to_owned().to_lower())
    .collect()
  if present.contains("*") {
    return headers
  }
  let mut out = headers
  for name in names {
    if !present.contains(name.to_lower()) {
      out = out.add("vary", name)
    }
  }
  out
}

///|
/// `response` with its body coded with `coding` (and `dictionary` for dcb
/// and dcz): the coded length is unknown, digests of the old bytes go, and a
/// strong ETag is weakened. A body that cannot be taken gives 500.
fn encoded_response(
  response : @mttp_core.Response,
  headers : @mttp_core.Headers,
  coding : Coding,
  dictionary : ServerDictionary?,
) -> @mttp_core.Response {
  let body = encode_body(response.body, coding, dictionary?) catch {
    _ => {
      response.close()
      return @mttp_core.Response::new(500)
    }
  }
  let headers = headers
    .remove("content-length")
    .remove("content-md5")
    .remove("content-digest")
    .set("content-encoding", coding.name())
  let headers = match headers.get("etag") {
    Some(tag) if !tag.has_prefix("W/") => headers.set("etag", "W/" + tag)
    _ => headers
  }
  { ..response, headers, body, }
}

///|
/// What `compress` does to one response, with `extra_vary` added to Vary
/// beside Accept-Encoding.
fn compress_response(
  request : @mttp_core.Request,
  response : @mttp_core.Response,
  min_bytes : Int32,
  extra_vary : Array[String],
) -> @mttp_core.Response {
  if !may_encode(request, response) {
    return response
  }
  let (choice, identity_ok) = choose_encoding(request.headers) catch {
    _ => {
      response.close()
      return @mttp_core.Response::new(400)
    }
  }
  let headers = add_vary(response.headers, ["Accept-Encoding", ..extra_vary])
  match choice {
    Identity => { ..response, headers, }
    Unacceptable => {
      response.close()
      @mttp_core.Response::new(
        406,
        headers=add_vary(
          @mttp_core.Headers::empty(),
          ["Accept-Encoding", ..extra_vary],
        ),
      )
    }
    Encoded(coding) => {
      if identity_ok &&
        response.body.length() is Some(length) &&
        length < min_bytes.max(0).to_int64() {
        return { ..response, headers, }
      }
      encoded_response(response, headers, coding, None)
    }
  }
}
