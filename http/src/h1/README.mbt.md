# gaato/http/h1

A sans-IO HTTP/1.1 codec: it turns bytes into heads, framing and body
payloads and back, and never performs I/O. The client and server connection
engines of `gaato/http` read and write every message with it, so both refuse
the same inputs. It follows the message syntax and framing of
[RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html), stricter where
lenient parsing lets two implementations read one message differently.

## Reading a message

Feed arriving bytes to a `HeadDecoder` until it returns the head; the bytes
after `consumed` start the body. Parse the head, resolve its framing, then
read the body by length or through a `ChunkedDecoder`. Every decoder scans
each byte once, keeps only bounded state and is sticky: after an error, every
later call raises the same error.

```mbt check
///|
test "read a chunked request" {
  let wire = b"POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
  let heads = @h1.HeadDecoder::new(skip_leading_crlf=true)
  let result = heads.feed(wire)
  guard result.head is Some(head) else { fail("head incomplete") }
  let request = @h1.parse_request_head(head)
  assert_eq(request.meth, Post)
  assert_eq(request.target, "/upload")
  guard @h1.request_framing(request.headers) is Chunked else {
    fail("expected a chunked body")
  }
  let body = @h1.ChunkedDecoder::new(@h1.Limits::default())
  let decoded = body.feed(wire[result.consumed:])
  assert_eq(decoded.chunks, [b"hello"])
  assert_true(decoded.done)
  body.finish()
}
```

A response's framing also depends on the request method and the status:
a response to HEAD, a 1xx, 204 or 304 and a successful CONNECT have no body,
and a response with neither Content-Length nor Transfer-Encoding ends when
the connection closes.

```mbt check
///|
test "resolve response framing" {
  let response = @h1.parse_response_head(
    b"HTTP/1.1 200\r\nContent-Length: 12\r\n\r\n",
  )
  assert_eq(
    @h1.response_framing(response.headers, status=response.status),
    Length(12),
  )
  assert_eq(
    @h1.response_framing(response.headers, status=response.status, meth=Head),
    NoBody,
  )
}
```

## Writing a message

`write_request_head` and `write_response_head` replace Content-Length and
Transfer-Encoding with the ones the given `Framing` implies and raise instead
of emitting bytes the parser would refuse. What they write reads back with
the same framing: `NoBody` becomes `Content-Length: 0` on a response that
would otherwise be read until close, and on a POST, PUT or PATCH request,
while a response that never has a body (to HEAD or a successful CONNECT, a
1xx, 204 or 304) and a request whose method expects no content get no
framing field. `write_response_head` takes the request method for this, as
`response_framing` does. `encode_chunk` frames one chunk; an empty one ends
the body.

```mbt check
///|
test "write a chunked response" {
  let head = @h1.write_response_head(
    200,
    @http.Headers::of([("Content-Type", "text/plain")]),
    Chunked,
    Http11,
  )
  let parsed = @h1.parse_response_head(head)
  assert_eq(@h1.response_framing(parsed.headers, status=parsed.status), Chunked)
  assert_eq(@h1.encode_chunk(b"hi"), b"2\r\nhi\r\n")
}
```

## What is refused

Every refusal is a `ParseError` whose `kind` says how to answer:

| Kind | Inputs | A server answers |
|---|---|---|
| `HeadTooLarge` | a head, chunk-size line or trailer section past its `Limits` | 431 for a head; 400 inside a body |
| `Malformed` | bare CR or LF, an empty line before a status line, obs-fold, whitespace before a colon, controls in a field, a missing or invalid `Host` on HTTP/1.1, an invalid target form, any duplicate Content-Length (even identical), an invalid or overflowing length or chunk size | 400 |
| `Smuggling` | Content-Length with Transfer-Encoding, Transfer-Encoding on HTTP/1.0, a framing or routing field in trailers | 400 |
| `Unsupported` | a transfer coding other than a single `chunked`, an HTTP version other than 1.x | 501 or 505 |

Each case closes the connection. `ParseKind` may grow, so a `match` on it
needs a wildcard arm.

Accepted although some parsers refuse them: a status line without a reason
phrase (`HTTP/1.1 200`), obs-text in field values (kept as Latin-1 code
points), and an HTTP/1 minor version above 1, read as HTTP/1.1.

A server skips empty lines (CRLF) before a request line, as RFC 9112
section 2.2 asks, because some clients send an extra CRLF after a request
body: `parse_request_head` does, and so does a `HeadDecoder` or `scan_head`
with `skip_leading_crlf=true`. The skipped bytes count against the head
limit. A leading bare LF is still refused, and so is an empty line before a
status line.

## Limits

| Bound | Default |
|---|---|
| Head, start line, final CRLF CRLF and skipped empty lines included | 16 KiB |
| Fields per head, and per trailer section | 100 |
| Chunk-size line, extensions and CRLF included | 4 KiB |
| Trailer section, final CRLF included | 16 KiB |

Chunk payloads are never buffered: a chunk declared as gigabytes long is
returned in pieces as its bytes arrive.
