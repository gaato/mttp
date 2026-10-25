# Content codings

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
  let headers = @model.Headers::of([("accept-encoding", "gzip;q=0.5, br;q=1")])
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
