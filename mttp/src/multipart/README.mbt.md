# gaato/mttp/multipart

A `multipart/form-data` writer ([RFC 7578](https://www.rfc-editor.org/rfc/rfc7578)):
text, JSON and file parts, with file bodies held in memory or streamed from a
`@http.BodyStream` as the request is sent.

- `body(request, parts, boundary~)` returns the request with the encoded body
  and its `Content-Type`. Without stream parts the body is one `Bytes`; with
  them it is a stream, sent with `Content-Length` only when every stream part
  declared its length.
- `encode`, `encode_segments` and `encode_body` return the content type and
  the body as one buffer, as ordered segments that share the part bodies, or
  as a request body.
- `make_boundary(random)` draws a boundary from the randomness the caller
  injects; nothing here reads a global random source.
  `encode_segments_fresh` draws again when an in-memory part contains the
  boundary.

The writer refuses rather than produces a body a receiver would split
differently: a boundary outside RFC 2046's rules (1 to 70 characters of
`bchars`, not ending with a space), a part content type with a control
character, and an in-memory part that contains the delimiter all raise
`MultipartError` before any byte is produced. `name` and `filename` escape
`"`, CR and LF as `%22`, `%0D` and `%0A`, as browsers do. A stream part cannot
be checked in advance, so it is scanned as it streams, keeping only how much
of the delimiter it has matched: one that contains the delimiter fails with
`@http.TransportError(Protocol, Body)` before its last byte goes out.

A stream part is sent once, like any `@http.StreamBody`. The multipart body
takes every part stream at its first read, closes them on every exit, and
leaves alone a part stream that another sender took.

```mbt check
///|
test "a text part and a file part" {
  let request = @multipart.body(
    @http.Request::post("https://example.com/upload"),
    [
      @multipart.Part::text("title", "notes"),
      @multipart.Part::file("file", "a.txt", "text/plain", b"hi"),
    ],
    boundary="XyZ",
  )
  assert_eq(
    request.headers.get("content-type"),
    Some("multipart/form-data; boundary=XyZ"),
  )
  assert_eq(
    request.body.as_bytes(),
    Some(
      b"--XyZ\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nnotes\r\n--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nhi\r\n--XyZ--\r\n",
    ),
  )
}

///|
test "a fresh boundary from injected randomness" {
  let boundary = @multipart.make_boundary(() => 0.5)
  assert_eq(boundary, "mttp-" + "i".repeat(32))
}
```
