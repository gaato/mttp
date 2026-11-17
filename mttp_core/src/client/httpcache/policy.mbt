///|
fn vary_names(headers : @mttp_core.Headers) -> Array[String] {
  let names = []
  for value in headers.get_all("vary") {
    for name in value.split(",") {
      let name = name.trim(chars=" \t").to_owned().to_lower()
      if !name.is_empty() && !names.contains(name) {
        names.push(name)
      }
    }
  }
  names
}

///|
fn selection(
  head : @mttp_core.Headers,
  request : @mttp_core.Headers,
) -> @mttp_core.Headers {
  let mut selected = @mttp_core.Headers::empty()
  for name in vary_names(head) {
    for value in request.get_all(name) {
      selected = selected.add(name, value)
    }
  }
  selected
}

///|
fn matches(stored : Stored, request : @mttp_core.Headers) -> Bool {
  !vary_names(stored.head.headers).contains("*") &&
  vary_names(stored.head.headers).all(name => {
    stored.vary_headers.get_all(name) == request.get_all(name)
  })
}

///|
fn storable(
  request : @mttp_core.Request,
  head : @mttp_core.ResponseHead,
) -> Bool {
  let cc = @cache.CacheControl::parse(head.headers.get_all("cache-control"))
  let req = @cache.CacheControl::parse(request.headers.get_all("cache-control"))
  let status = head.status
  let understood = match status {
    200 | 203 | 204 | 300 | 301 | 308 | 404 | 405 | 410 | 414 | 501 => true
    _ => false
  }
  request.meth == Get &&
  !request.headers.contains("range") &&
  !req.no_store &&
  !cc.no_store &&
  !vary_names(head.headers).contains("*") &&
  status >= 200 &&
  !@mttp_core.reason_phrase(status).is_empty() &&
  status != 206 &&
  status != 304 &&
  status <= 599 &&
  (
    understood ||
    cc.max_age is Some(_) ||
    head.headers.contains("expires") ||
    cc.is_public ||
    cc.is_private
  )
}

///|
fn HttpCache::freshness(
  self : HttpCache,
  key : CacheKey,
  stored : Stored,
) -> @cache.Freshness {
  let f = @cache.Freshness::of(
    stored.head.headers,
    shared=false,
    request_time_ms=stored.request_time_ms,
    response_time_ms=stored.response_time_ms,
    now_ms=self.clock.now_unix_ms(),
  )
  if f.lifetime is Some(_) || key.url.contains("?") {
    return f
  }
  {
    ..f,
    lifetime: @cache.heuristic_lifetime(
      stored.head.headers,
      stored.head.status,
      percent=self.heuristic_percent,
    ),
  }
}

///|
fn usable(f : @cache.Freshness, req : @cache.CacheControl) -> Bool {
  if req.no_cache || f.cache_control.no_cache {
    return false
  }
  if req.max_age is Some(max) && f.age > max {
    return false
  }
  if req.min_fresh is Some(min) && f.age + min >= f.lifetime.unwrap_or(0L) {
    return false
  }
  if f.reusable() {
    return true
  }
  !f.stale_forbidden() &&
  (req.max_stale_any || (req.max_stale is Some(max) && f.staleness() <= max))
}

///|
/// Hop-by-hop fields cannot become representation metadata, including fields
/// nominated by Connection. Content-Length in a 304 cannot replace body size.
fn end_to_end(headers : @mttp_core.Headers) -> @mttp_core.Headers {
  let mut out = headers
  for connection in headers.get_all("connection") {
    for name in connection.split(",") {
      out = out.remove(name.trim().to_owned())
    }
  }
  for
    name in [
      "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
      "trailer", "transfer-encoding", "upgrade",
    ] {
    out = out.remove(name)
  }
  out
}

///|
fn merged_headers(
  old : @mttp_core.Headers,
  update : @mttp_core.Headers,
) -> @mttp_core.Headers {
  let update = end_to_end(update).remove("content-length")
  let mut out = old
  for (name, _) in update.iter() {
    out = out.remove(name)
  }
  for (name, value) in update.iter() {
    out = out.add(name, value)
  }
  out
}

///|
fn marked(
  response : @mttp_core.Response,
  status : CacheStatus,
) -> @mttp_core.Response {
  { ..response, attributes: response.attributes.put(cache_status, status), }
}

///|
fn HttpCache::cached(
  self : HttpCache,
  key : CacheKey,
  stored : Stored,
  request : @mttp_core.Request,
  status : CacheStatus,
) -> @mttp_core.Response {
  let age = self.freshness(key, stored).age
  marked(
    @mttp_core.Response::new(
      stored.head.status,
      headers=stored.head.headers.set("age", age.to_string()),
      body=if request.meth == Head { Empty } else { Bytes(stored.body) },
    ),
    status,
  )
}
