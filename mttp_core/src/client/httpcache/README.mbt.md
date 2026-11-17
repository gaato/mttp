# Private HTTP cache

`HttpCache` implements the Backend port without I/O or a runtime dependency.
Use `AuthRefresh(HttpCache(Decompress(engine)))`: refresh sets Authorization
before cache lookup, and decompression finishes before bytes are stored.

```mbt check
///|
test "private cache stack" {
  let clock = @sim.FakeClock::new()
  let inner = @client.from_fn((_, _) => @mttp_core.Response::new(200))
  let cache = @httpcache.HttpCache::new(inner, clock~)
  let backend : &@mttp_core.Backend = cache
  backend.close()
}
```

GET representations are collected as the caller reads, committed only at EOF,
and may answer HEAD without a body. Closing, cancelling or failing a read does
not commit. `SendOptions` and unknown response attributes pass through network
responses; synthetic cache responses carry `cache_status` and current `Age`.
Caller conditionals and Range bypass lookup and storage. Only-if-cached never
accesses the network and returns 504 when a representation cannot be used.
Request no-cache, max-age, min-fresh, max-stale and legacy Pragma are respected.

Freshness uses `cache.Freshness`, augmented by 10% of Date minus Last-Modified
for heuristically cacheable statuses without explicit expiration. Query URLs
have no heuristic. Set `heuristic_percent=0` to disable it. Stale responses
validate with ETag, otherwise Last-Modified. A matching 304 updates end-to-end
metadata and freshness; a full response replaces the representation when read.
Stale-if-error is limited to 500/502/503/504 and transport failure, and the
existing Freshness policy forbids it under no-cache or must-revalidate.
Background stale-while-revalidate, ranges, shared caching and disk are excluded.

The default MemoryStore is an LRU of at most 1024 representations and 16 MiB
of bodies plus URL, credential and header UTF-16 storage. An oversize entry is
not retained. `max_entry_bytes=1048576` bounds each collected body; exceeding
it releases the collection but continues delivering the body. `max_variants=8`
limits Vary selections per key. Negative limits count as zero. Zero variants
or entries disables storage; a zero body limit permits only empty bodies.
Variant eviction is oldest selection first, URL eviction is LRU.

Authorization is part of CacheKey under `Partition`, including a distinct
anonymous partition. Its raw value exists only in memory by default.
**An injected store must hash the credential before persisting keys.**
`Bypass` skips credentialed requests. Successful unsafe methods invalidate
the target and same-origin Location/Content-Location across credential
partitions. Bodies already being read cannot repopulate an invalidated cache.

CacheStore lookup returns oldest variants first; insert replaces equal request
Vary headers. `remove` invalidates every partition of the URL, so an
authenticated mutation also invalidates anonymous reads. Variant eviction and
304 replacement may conservatively discard other partitions of the same URL.
Store operations may raise: failures degrade to misses or skipped
writes. Injected implementations must make their methods concurrency-safe.
The wrapper serializes offers, dropping overlapping ones instead of exceeding
variant limits; it does not coalesce network requests. Store instances should
be owned by one wrapper if wrapper-specific variant limits are required.
