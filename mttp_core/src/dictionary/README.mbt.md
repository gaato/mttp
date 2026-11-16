# gaato/mttp_core/dictionary

A client's compression dictionaries, as
[RFC 9842](https://www.rfc-editor.org/rfc/rfc9842) section 2 keeps and
offers them, without I/O.

`DictionaryStore::offer` takes a response that ended cleanly: it becomes a
dictionary when the request went to an https URL or a loopback host, it
carries a valid `Use-As-Dictionary` whose `match` is a URL pattern without
regular expressions, it may be stored, and it is fresh (or stale within its
stale-while-revalidate window, section 2.2.1). `select` gives the
dictionary a request should advertise with `Available-Dictionary` and
`Dictionary-ID`, chosen as section 2.2.3 says; `find` gives the one a
response's hash names. Dictionaries are kept per partition, as section 10
asks of cookie-like state; `clear` forgets them.

A `match` is resolved against the dictionary's own URL. RFC 9842 section
2.1.1 says so when it validates the pattern; section 2.2.2 writes the
request's URL as the base when it matches, but both URLs are of one
origin and the section names the dictionary's URL BASEURL, so the
dictionary's is taken for both, and a relative `match` means the same
whichever request it is tested against.

mttp_core carries no SHA-256, so the store is given one; with
`moonbitlang/x`, `sha256=data => Bytes::from_array(@crypto.sha256(data))`.

It is bounded:

- 64 dictionaries, 4 MiB each and 32 MiB in all by default
  (`max_entries`, `max_dictionary_bytes`, `max_total_bytes`); past a cap the
  oldest go first, and a new response for a stored URL replaces it;
- a `Use-As-Dictionary` field of more than 8 KiB, a `match` of more than
  1024 characters or an `id` of more than 1024 is ignored.

```mbt check
///|
test "store a dictionary and offer it to a matching request" {
  let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
  // A stand-in for SHA-256; use a real one.
  let sha256 = (data : BytesView) => Bytes::make(32, data.length().to_byte())
  let store = @dictionary.DictionaryStore::new(sha256~, clock~)
  let headers = @mttp_core.Headers::of([
    ("use-as-dictionary", "match=\"/app/*/main.js\", id=\"v1\""),
    ("cache-control", "max-age=86400"),
  ])
  let stored = store.offer(
    @mttp_core.Url::parse("https://example.com/app/v1/main.js"),
    headers,
    b"the dictionary",
    request_time_ms=1_000_000L,
  )
  assert_true(stored)
  let d = store
    .select(@mttp_core.Url::parse("https://example.com/app/v2/main.js"))
    .unwrap()
  assert_eq(d.dictionary_id(), Some("\"v1\""))
  assert_true(d.available_dictionary().has_prefix(":"))
}
```
