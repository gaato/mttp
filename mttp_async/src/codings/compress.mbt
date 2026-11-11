///|
/// Negotiates gzip, deflate or Brotli for a response. Known bodies smaller
/// than min_bytes (default 1024, negatives clamp to zero) are passed through;
/// unknown-length streams are compressed without prefetching. Every input
/// chunk is sync-flushed and output slices are at most 64 KiB. Skips HEAD,
/// bodyless statuses, Range/206/Content-Range and already encoded responses.
/// Invalid negotiation returns 400; refusal of every encoding returns 406.
pub fn compress(
  handler : @mttp.Handler,
  min_bytes~ : Int32 = 1024,
) -> @mttp.Handler {
  request => {
    let response = handler(request)
    if !has_body(request.meth.to_string(), response.status) ||
      request.headers.contains("range") ||
      response.status == 206 ||
      response.headers.contains("content-range") ||
      response.headers
      .get_all("cache-control")
      .join(",")
      .split(",")
      .any(token => token.trim().to_owned().to_lower() == "no-transform") ||
      response.headers.contains("content-encoding") {
      return response
    }
    let (choice, identity_ok) = choose_encoding(request.headers) catch {
      _ => {
        response.close()
        return @mttp.Response::new(400)
      }
    }
    let vary = response.headers.get_all("vary").join(", ")
    let headers = if vary
      .split(",")
      .any(token => {
        let name = token.trim().to_owned().to_lower()
        name == "accept-encoding" || name == "*"
      }) {
      response.headers
    } else {
      response.headers.add("vary", "Accept-Encoding")
    }
    match choice {
      Identity => { ..response, headers, }
      Unacceptable => {
        response.close()
        @mttp.Response::new(
          406,
          headers=@mttp.Headers::of([("vary", "Accept-Encoding")]),
        )
      }
      Encoded(coding) => {
        if identity_ok &&
          response.body.length() is Some(length) &&
          length < min_bytes.max(0).to_int64() {
          return { ..response, headers, }
        }
        let body = encode_body(response.body, coding) catch {
          _ => {
            response.close()
            return @mttp.Response::new(500)
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
    }
  }
}
