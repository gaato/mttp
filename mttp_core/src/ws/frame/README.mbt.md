# WebSocket frames without I/O

`gaato/mttp_core/ws/frame` implements RFC 6455 frame syntax, masking and
strict incremental RFC 3629 validation. The role is the endpoint reading the
frames. Servers require masked input; clients require unmasked input.

```mbt check
///|
test {
  let parser = @frame.Parser::new(
    role=Client,
    max_frame_bytes=16777216,
    allow_rsv1=false,
  )
  parser.feed(b"\x81\x02hi")
  assert_true(parser.next() is Some(Head({ opcode: Text, length: 2L, .. })))
  assert_eq(parser.next(), Some(@frame.Event::Payload(b"hi")))
  assert_eq(parser.next(), Some(@frame.Event::End))
  assert_eq(parser.next(), None)
  let utf8 = @frame.Utf8Validator::new()
  assert_true(utf8.push(b"\xf0\x9f"))
  assert_false(utf8.finish())
  assert_true(utf8.push(b"\x99\x82"))
  assert_true(utf8.finish())
}
```

Each frame produces `Head(FrameHead)`, zero or more `Payload(Bytes)` pieces
already unmasked, and `End`. Piece boundaries depend on feed boundaries;
concatenating each frame's payload gives identical results under any split.
`None` requests more input, including for a truncated frame; the Session
engine handles transport EOF. Errors remain sticky, with Protocol → 1002 and
TooLarge → 1009. A negative frame limit fails on the first `next`.

Drain `next` until `None` before feeding another read. The parser retains
views of queued input, uses a fixed fourteen-byte head buffer, and allocates
each returned payload only for the available input piece. The caller bounds
read sizes and outstanding feeds. `encode_head` requires a four-byte mask
key exactly when `head.masked` is true. `apply_mask` accepts an offset for
incremental masking; randomness is supplied by its caller.

Frame syntax rejects one-byte Close payloads; `ws` owns Close code/reason
parsing alongside its CloseCode and CloseFrame types. Fragment ordering,
message limits, extension decoding and text-message validation are Session
responsibilities. `allow_rsv1` permits negotiated data-frame extensions;
controls never carry RSV1. Start a fresh Utf8Validator for each text message;
retain it across continuation frames. `finish` checks completeness so far
without mutating the validator; an invalid byte permanently poisons it.
