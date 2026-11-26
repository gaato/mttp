///|
/// RFC 9111 private GET cache. Compose AuthRefresh(HttpCache(Decompress(engine)))
/// so credentials select a partition and stored bytes are decoded.
pub struct HttpCache {
  priv inner : &@mttp_core.Backend
  priv clock : &@rt.Clock
  priv store : &CacheStore
  priv heuristic_percent : Int32
  priv credentials : CredentialMode
  priv max_entry_bytes : Int32
  priv max_variants : Int32
  priv mut closed : Bool
  priv mut generation : Int64
  priv mut writing : Bool
  priv mut disabled : Bool
}

///|
/// Creates a private cache, using a bounded MemoryStore when no store is supplied.
/// Takes ownership of closing the wrapped backend; negative limits clamp to zero.
pub fn HttpCache::new(
  inner : &@mttp_core.Backend,
  clock~ : &@rt.Clock,
  store? : &CacheStore,
  heuristic_percent~ : Int32 = 10,
  credentials~ : CredentialMode = Partition,
  max_entry_bytes~ : Int32 = 1048576,
  max_variants~ : Int32 = 8,
) -> HttpCache {
  {
    inner,
    clock,
    store: store.unwrap_or(MemoryStore::new()),
    heuristic_percent,
    credentials,
    max_entry_bytes: max_entry_bytes.max(0),
    max_variants: max_variants.max(0),
    closed: false,
    generation: 0L,
    writing: false,
    disabled: false,
  }
}

///|
/// Store errors are best effort; they must not replace a transport response.
#warnings("-fragile_catch_all")
async fn HttpCache::lookup(
  self : HttpCache,
  key : CacheKey,
) -> Array[Stored] noraise {
  let entries = self.store.lookup(key) catch { _ => [] }
  // A concurrent invalidation may have failed while lookup was suspended.
  if self.disabled {
    []
  } else {
    entries
  }
}

///|
#warnings("-fragile_catch_all")
async fn HttpCache::remove(self : HttpCache, key : CacheKey) -> Unit noraise {
  self.store.remove(key) catch {
    // Entries that could not be removed can no longer be trusted. A single
    // flag also bounds this fallback independently of the number of URLs.
    _ => self.disabled = true
  }
}

///|
/// Serialize offers without holding a lock across caller reads. Concurrent
/// offers may be dropped: caching is optional, exceeding its bounds is not.
#warnings("-fragile_catch_all")
async fn HttpCache::offer(
  self : HttpCache,
  key : CacheKey,
  stored : Stored,
  generation : Int64,
) -> Unit noraise {
  if self.closed ||
    self.disabled ||
    self.writing ||
    generation != self.generation ||
    self.max_variants == 0 {
    return
  }
  self.writing = true
  defer {
    self.writing = false
  }
  try {
    let variants = self.store.lookup(key)
    let keep = variants.filter(s => s.vary_headers != stored.vary_headers)
    if keep.length() >= self.max_variants {
      self.remove(key)
      if self.disabled {
        return
      }
      let start = keep.length() - self.max_variants + 1
      for i in start..<keep.length() {
        self.store.insert(key, keep[i])
      }
    }
    if generation == self.generation && !self.closed && !self.disabled {
      self.store.insert(key, stored)
    }
    if generation != self.generation || self.closed {
      self.remove(key)
    }
  } catch {
    _ => ()
  }
}

///|
async fn HttpCache::invalidate(
  self : HttpCache,
  request : @mttp_core.Request,
  response : @mttp_core.Response,
  key : CacheKey,
) -> Unit noraise {
  self.generation += 1L
  self.remove(key)
  let origin = @mttp_core.Url::parse(key.url) catch { _ => return }
  for name in ["location", "content-location"] {
    for value in response.headers.get_all(name) {
      let relative = @mttp_core.Url::parse(value) catch { _ => continue }
      let url = origin.resolve(relative).without_fragment()
      if origin.same_origin(url) {
        self.remove({
          url: key_url(url),
          credential: request.headers.get("authorization"),
        })
      }
    }
  }
}

///|
/// Sends a request through the cache and records its cache status on the response.
/// Closes request streams on every exit; sends after close raise Closed.
pub async fn HttpCache::send(
  self : HttpCache,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  defer (if request.body is Stream(s) { s.close() })
  if self.closed {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Pool,
      detail="HTTP cache is closed",
    )
  }
  request.validate()
  options.validate()
  let req = @cache.CacheControl::parse(request.headers.get_all("cache-control"))
  let force_validation = req.no_cache ||
    (
      request.headers.get_all("cache-control").is_empty() &&
      @cache.CacheControl::parse(request.headers.get_all("pragma")).no_cache
    )
  let parsed = try @mttp_core.Url::parse(request.url) catch {
    _ => None
  } noraise {
    u => Some(u)
  }
  let key : CacheKey = {
    url: match parsed {
      Some(u) => key_url(u)
      None => request.url
    },
    credential: request.headers.get("authorization"),
  }
  let safe = request.meth == Get ||
    request.meth == Head ||
    request.meth == Options ||
    request.meth == Trace
  let conditional = [
    "if-none-match", "if-modified-since", "if-match", "if-unmodified-since", "if-range",
  ].any(n => request.headers.contains(n))
  let bypass = self.disabled ||
    (self.credentials == Bypass && key.credential is Some(_)) ||
    req.no_store ||
    request.headers.contains("range") ||
    conditional ||
    (request.meth != Get && request.meth != Head) ||
    parsed is None ||
    request.body.length() != Some(0L) ||
    request.body is Stream(_)
  let mut stored : Stored? = None
  if !bypass {
    for variant in self.lookup(key) {
      if matches(variant, request.headers) {
        stored = Some(variant)
      }
    }
    if stored is Some(s) &&
      usable(self.freshness(key, s), req) &&
      !force_validation {
      let status = if self.freshness(key, s).is_fresh() { Hit } else { Stale }
      return self.cached(key, s, request, status)
    }
  }
  if req.only_if_cached {
    return marked(
      @mttp_core.Response::new(504),
      if bypass {
        Bypass
      } else {
        Miss
      },
    )
  }
  let mut sent = request
  if stored is Some(s) {
    if s.head.headers.get("etag") is Some(etag) {
      sent = sent.set_header("if-none-match", etag)
    } else if s.head.headers.get("last-modified") is Some(date) {
      sent = sent.set_header("if-modified-since", date)
    }
  }
  let generation = self.generation
  let request_time_ms = self.clock.now_unix_ms()
  let response = self.inner.send(sent, options) catch {
    @mttp_core.TransportError(..) as error => {
      if stored is Some(s) &&
        !force_validation &&
        self.freshness(key, s).may_serve_on_error(request=req) {
        return self.cached(key, s, request, Stale)
      }
      raise error
    }
  }
  let response_time_ms = self.clock.now_unix_ms()
  let (response, request_time_ms, response_time_ms, generation) = if response.status ==
    304 &&
    stored is Some(s) &&
    !validation_matches(s, response.headers) {
    // This 304 does not identify reusable bytes. Release it before another
    // send, including on a one-slot backend, and do not promote its validator.
    @rt.close_unclaimed(response.attributes)
    response.close()
    self.generation += 1L
    let generation = self.generation
    self.remove(key)
    stored = None
    let request_time_ms = self.clock.now_unix_ms()
    let full = self.inner.send(request, options)
    let response_time_ms = self.clock.now_unix_ms()
    if full.status == 304 {
      // One unconditional retry is enough: a further 304 cannot satisfy an
      // unconditional request, and must not turn into a retry loop.
      @rt.close_unclaimed(full.attributes)
      full.close()
      raise @mttp_core.TransportError(
        kind=Protocol,
        phase=Head,
        detail="304 response to unconditional cache refetch",
      )
    }
    (full, request_time_ms, response_time_ms, generation)
  } else {
    (response, request_time_ms, response_time_ms, generation)
  }
  errdefer {
    @rt.close_unclaimed(response.attributes)
    response.close()
  }
  if !safe && response.status >= 200 && response.status < 400 {
    self.invalidate(request, response, key)
  }
  if stored is Some(s) {
    if response.status == 304 &&
      validation_matches(s, response.headers) &&
      (request.meth == Get || request.meth == Head) &&
      (
        s.head.headers.contains("etag") ||
        s.head.headers.contains("last-modified")
      ) {
      let update = if response.headers.contains("date") {
        response.headers
      } else {
        response.headers.set(
          "date",
          @mttp_core.format_http_date(response_time_ms),
        )
      }
      let headers = merged_headers(s.head.headers, update)
      let updated = {
        ..s,
        head: { ..s.head, headers, },
        vary_headers: selection(headers, request.headers),
        request_time_ms,
        response_time_ms,
      }
      @rt.close_unclaimed(response.attributes)
      response.close()
      self.remove(key)
      if storable({ ..request, meth: Get, }, updated.head) {
        self.offer(key, updated, generation)
      }
      return {
        ..self.cached(key, updated, request, Revalidated),
        attributes: response.attributes.put(cache_status, Revalidated),
      }
    }
    if [500, 502, 503, 504].contains(response.status) &&
      !force_validation &&
      self.freshness(key, s).may_serve_on_error(request=req) {
      @rt.close_unclaimed(response.attributes)
      response.close()
      return self.cached(key, s, request, Stale)
    }
  }
  if request.meth == Head &&
    response.status == 200 &&
    stored is Some(s) &&
    head_conflicts(s, response.headers) {
    self.generation += 1L
    self.remove(key)
  }
  let response = marked(response, if bypass { Bypass } else { Miss })
  if bypass || !storable(request, response.head()) {
    return response
  }
  let head = { ..response.head(), headers: end_to_end(response.headers), }
  let base : Stored = {
    vary_headers: selection(head.headers, request.headers),
    head,
    body: b"",
    request_time_ms,
    response_time_ms,
  }
  let (read, close_) = source(response.body)
  {
    ..response,
    body: Stream(
      @mttp_core.StreamBody::new(
        Collected::{
          read,
          close_,
          origin: response.body,
          buffer: Buffer(capacity=0),
          limit: self.max_entry_bytes,
          over: false,
          closed: false,
          commit: body => self.offer(key, { ..base, body, }, generation),
        },
        length?=response.body.length(),
      ),
    ),
  }
}

///|
/// Closes the wrapped backend once and prevents later sends and cache writes.
pub fn HttpCache::close(self : HttpCache) -> Unit {
  if !self.closed {
    self.closed = true
    self.generation += 1L
    self.inner.close()
  }
}

///|
/// Sends through the cache using the Backend interface.
pub impl @mttp_core.Backend for HttpCache with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// Closes the cache and its wrapped backend using the Backend interface.
pub impl @mttp_core.Backend for HttpCache with fn close(self) {
  self.close()
}
