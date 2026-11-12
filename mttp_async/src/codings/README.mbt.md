# gaato/mttp_async/codings

Bounded content codings for native, wasm (under moonrun) and js.

`ContentDecoder` incrementally decodes gzip, deflate, Brotli and zstd.
`ContentEncoder` produces gzip, zlib-wrapped deflate and Brotli; the current
codec dependency has no zstd encoder. Both use feed/pull/end and return slices
of at most 64 KiB. Feed only after `NeedInput`; end at the final `NeedInput`.

`encode_body` transfers a streamed body's reader and returns a lazy compressed
body with unknown length. Its source closes on EOF, failure, cancellation or
explicit close. The caller must set Content-Encoding and remove Content-Length
when writing that body. Buffered bodies are read in 64 KiB pieces.

```mbt check
///|
test "negotiate a response encoding" {
  let headers = @mttp.Headers::of([("accept-encoding", "gzip;q=0.5, br;q=1")])
  assert_eq(@codings.negotiate_encoding(headers), @codings.Encoded(Brotli))
}
```

Negotiation follows [RFC 9110 section 12.5.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-12.5.3).
The implementation chooses identity when the field is absent, although HTTP
permits compression then. Repeated names use the lowest weight, so an explicit
exclusion cannot be undone by a duplicate. `Unacceptable` lets the adapter
reject a request that refuses identity and every available encoding. Malformed
weights or more than 16 KiB / 128 entries raise Invalid in the Head phase.

Every encoder feed is sync-flushed: a consumer can decode the emitted bytes
before upstream EOF, including for live events. This trades some compression
ratio for bounded response latency. Codec state is bounded independently of
total input, while the caller retains responsibility for upstream chunk size.

`Decompress::new(inner)` wraps a `gaato/mttp.Backend`. It adds
`Accept-Encoding: gzip, deflate, br, zstd` only when the caller supplied no
Accept-Encoding field. Any explicit field, including `identity`, opts out
of negotiation and decoding. It undoes known outer codings, keeps any unknown
inner codings, and removes the decoded Content-Encoding entries and the coded
Content-Length. HEAD and bodyless statuses keep their representation metadata.
It passes SendOptions unchanged: the engine counts wire bytes and the caller's
reader bounds decoded bytes. Decoding is lazy and closes its upstream source
on EOF, error, cancellation, or early close.

`compress(handler, min_bytes=1024)` negotiates gzip, deflate or Brotli and
returns a Handler. It skips HEAD, 1xx, 204, 304, Range requests, 206 and
Content-Range responses, already encoded responses and `Cache-Control:
no-transform`. A known length below the threshold stays unencoded when
identity is allowed; unknown-length streams are compressed without prefetching.
Negative thresholds mean zero. If identity is explicitly forbidden, a small
response still uses an acceptable coding. Invalid negotiation returns 400;
refusal of all supported encodings returns 406, closing the discarded body.
Failure to acquire the response stream returns 500 and closes it.

Compression adds `Vary: Accept-Encoding` without duplicating it or `*`, drops
Content-Length and encoded-byte digests, and weakens a strong ETag. Response
attributes are preserved. `encode_body` and both wrappers transfer a stream
reader exactly once; consumers close the returned response after use.
