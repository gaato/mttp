///|
fn request_content_types() -> Array[String] {
  [
    "application/json", "application/*+json", "text/*", "application/xml", "application/x-www-form-urlencoded",
  ]
}

///|
fn request_coding(coding : Coding) -> Unit raise @mttp_core.TransportError {
  if coding is (Dcb | Dcz) {
    raise invalid_encoding("request compression does not support dictionaries")
  }
}

///|
fn request_type_matches(
  headers : @mttp_core.Headers,
  patterns : Array[String],
) -> Bool {
  guard headers.get_all("content-type") is [field] else { return false }
  let media = field.split(";").collect()[0].trim().to_owned().to_lower()
  guard media.split("/").collect() is [type_, subtype] &&
    !type_.is_empty() &&
    !subtype.is_empty() else {
    return false
  }
  patterns.any(pattern => {
    let pattern = pattern.trim().to_owned().to_lower()
    match pattern.split("*").collect() {
      [exact] => media[:] == exact
      [prefix, suffix] =>
        media.has_prefix(prefix) &&
        media.has_suffix(suffix) &&
        media.length() > prefix.length() + suffix.length()
      _ => false
    }
  })
}

///|
fn compressed_request(
  request : @mttp_core.Request,
  coding : Coding,
  min_bytes : Int32,
  content_types : Array[String],
  streams : Bool,
) -> @mttp_core.Request raise @mttp_core.TransportError {
  if request.headers.contains("content-encoding") ||
    ["content-digest", "repr-digest", "content-md5", "signature-input"].any(name => {
      request.headers.contains(name)
    }) ||
    !request_type_matches(request.headers, content_types) {
    return request
  }
  if request.body.length() is Some(length) &&
    (length == 0L || length < min_bytes.max(0).to_int64()) {
    return request
  }
  let body = match request.body {
    Bytes(bytes) => {
      let encoder = ContentEncoder::new(coding)
      let out = Buffer()
      encoder.feed(bytes)
      for ;; {
        match encoder.pull() {
          Slice(chunk) => out.write_bytes(chunk)
          NeedInput => encoder.end()
          Done => break
        }
      }
      @mttp_core.Body::Bytes(out.to_bytes())
    }
    Stream(_) if streams => encode_body(request.body, coding)
    _ => return request
  }
  let headers = request.headers
    .remove("content-length")
    .remove("transfer-encoding")
    .set("content-encoding", coding.name())
  let headers = match body.length() {
    Some(length) => headers.set("content-length", length.to_string())
    None => headers
  }
  { ..request, headers, body, }
}

///|
/// Compresses one request using the default content types and 1024-byte
/// threshold (negative thresholds clamp to zero). Bytes are compressed now
/// and remain replayable. This explicit opt-in also takes an eligible stream
/// once, encoding lazily with unknown length and no prefetch. Protected or
/// already encoded requests pass through. Dcb and Dcz raise Invalid.
pub fn compress_request(
  request : @mttp_core.Request,
  coding : Coding,
  min_bytes? : Int32,
) -> @mttp_core.Request raise @mttp_core.TransportError {
  request_coding(coding)
  request.validate()
  compressed_request(
    request,
    coding,
    min_bytes.unwrap_or(1024),
    request_content_types(),
    true,
  )
}

///|
/// Opt-in request compression. Put outside DigestScheme so auth-int hashes
/// the bytes sent. Client retries recompress per attempt; compress_request
/// compresses Bytes once up front instead. Buffered compression holds about
/// twice the body plus codec state; streams use the existing 64 KiB encoder
/// bound. No per-origin acceptance is remembered.
pub struct CompressRequests {
  priv inner : &@mttp_core.Backend
  priv coding : Coding
  priv min_bytes : Int32
  priv content_types : Array[String]
  priv streams : Bool
  priv fallback_on_415 : Bool
  priv mut closed : Bool
}

///|
/// Takes ownership of closing inner. Dcb and Dcz raise Invalid before any
/// body is taken. Streams default off; enabled streams have unknown length.
pub fn CompressRequests::new(
  inner : &@mttp_core.Backend,
  coding~ : Coding = Gzip,
  min_bytes~ : Int32 = 1024,
  content_types~ : Array[String] = request_content_types(),
  streams~ : Bool = false,
  fallback_on_415~ : Bool = true,
) -> CompressRequests raise @mttp_core.TransportError {
  request_coding(coding)
  {
    inner,
    coding,
    min_bytes,
    content_types: content_types.copy(),
    streams,
    fallback_on_415,
    closed: false,
  }
}

///|
pub extend CompressRequests with @mttp_core.Backend::{send, close}

///|
fn excludes_request_coding(
  headers : @mttp_core.Headers,
  coding : Coding,
) -> Bool {
  let weights = encoding_weights(headers) catch { _ => return false }
  guard weights is Some(weights) else { return false }
  // The negotiation parser ignores unknown names. A retry needs a valid
  // diagnostic, so reject malformed names rather than treating them as an
  // exclusion. Reuse the HTTP token validator after the parser's bounds.
  for field in headers.get_all("accept-encoding") {
    for entry in field.split(",") {
      if entry.trim(chars=" \t").is_empty() {
        continue
      }
      let token = entry.split(";").collect()[0].trim(chars=" \t").to_owned()
      @mttp_core.Headers::of([(token, "")]).validate() catch {
        _ => return false
      }
    }
  }
  let index = match coding {
    Gzip => 0
    Deflate => 1
    Brotli => 2
    Zstd => 5
    _ => return false
  }
  weights[index].unwrap_or(weights[4].unwrap_or(0)) == 0
}

///|
/// Validates before taking a stream or delegating. A 415 only triggers a
/// single uncompressed resend when its Accept-Encoding excludes our coding
/// and the original body is still replayable. Malformed hints are ignored.
pub impl @mttp_core.Backend for CompressRequests with fn send(
  self,
  request,
  options,
) {
  if self.closed {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Pool,
      detail="backend closed",
    )
  }
  request.validate()
  options.validate()
  let sent = compressed_request(
    request,
    self.coding,
    self.min_bytes,
    self.content_types,
    self.streams,
  )
  let changed = !request.headers.contains("content-encoding") &&
    sent.headers.contains("content-encoding")
  let response = self.inner.send(sent, options)
  if self.fallback_on_415 &&
    changed &&
    response.status == 415 &&
    request.body.is_replayable() &&
    excludes_request_coding(response.headers, self.coding) {
    @rt.close_unclaimed(response.attributes)
    response.close()
    return self.inner.send(request, options)
  }
  response
}

///|
/// Closes the wrapped backend once and refuses later sends.
pub impl @mttp_core.Backend for CompressRequests with fn close(self) {
  if !self.closed {
    self.closed = true
    self.inner.close()
  }
}
