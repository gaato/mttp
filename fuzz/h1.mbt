// The HTTP/1.1 target: the reader that reader_test.mbt in mttp_core/src/h1
// builds on the codec, run whole, cut at a fuzzer-chosen place and fed one
// byte at a time, with the same invariants as h1/property_test.mbt: every
// input ends in a message or a ParseKind (never another error or a panic),
// the outcome does not depend on the cut, and a message the reader accepts
// reads back the same after the writer writes it again.

///|
#derive(Eq, Debug)
struct Message {
  head : Bytes
  framing : @h1.Framing
  body : Bytes
  trailers : @mttp_core.Headers
  rest : Bytes
}

///|
fn read_message(
  pieces : Array[Bytes],
  limits : @h1.Limits,
  skip_leading_crlf~ : Bool,
  framing : (Bytes) -> @h1.Framing raise @h1.ParseError,
) -> Result[Message, @h1.ParseKind] raise {
  try {
    let decoder = @h1.HeadDecoder::new(
      max=limits.max_head_bytes,
      skip_leading_crlf~,
    )
    let after_head : Array[BytesView] = []
    for piece in pieces {
      if after_head.is_empty() {
        let result = decoder.feed(piece)
        if result.head is Some(_) {
          after_head.push(piece[result.consumed:])
        }
      } else {
        after_head.push(piece)
      }
    }
    let head = decoder.finish()
    let framing = framing(head)
    let body = Buffer()
    let rest = Buffer()
    let mut trailers = @mttp_core.Headers::empty()
    match framing {
      Chunked => {
        let chunked = @h1.ChunkedDecoder::new(limits)
        for piece in after_head {
          let result = chunked.feed(piece)
          for chunk in result.chunks {
            guard !chunk.is_empty() else { fail("empty chunk emitted") }
            body.write_bytes(chunk)
          }
          rest.write_bytesview(piece[result.consumed:])
          trailers = result.trailers
        }
        chunked.finish()
      }
      Length(n) =>
        for piece in after_head {
          let take = (n - body.length().to_int64())
            .min(piece.length().to_int64())
            .to_int()
          body.write_bytesview(piece[:take])
          rest.write_bytesview(piece[take:])
        }
      UntilClose => after_head.each(piece => body.write_bytesview(piece))
      _ => after_head.each(piece => rest.write_bytesview(piece))
    }
    Ok({
      head,
      framing,
      body: body.to_bytes(),
      trailers,
      rest: rest.to_bytes(),
    })
  } catch {
    @h1.ParseError(kind~, ..) => Err(kind)
    error => raise error
  }
}

///|
let methods : Array[@mttp_core.Method] = [Get, Head, Post, Connect, Options]

///|
fn read(
  pieces : Array[Bytes],
  response : Bool,
  meth : @mttp_core.Method,
  limits : @h1.Limits,
) -> Result[Message, @h1.ParseKind] raise {
  if response {
    read_message(pieces, limits, skip_leading_crlf=false, head => {
      let r = @h1.parse_response_head(head, limits~)
      @h1.response_framing(r.headers, status=r.status, meth~)
    })
  } else {
    read_message(pieces, limits, skip_leading_crlf=true, head => {
      @h1.request_framing(@h1.parse_request_head(head, limits~).headers)
    })
  }
}

///|
/// Input: [mode, cut_hi, cut_lo, ..wire]. mode bit 0: response; bits 1-3:
/// method; bit 4: small limits.
pub fn fuzz_h1(data : Bytes) -> Int32 {
  if data.length() < 3 {
    return 0
  }
  let mode = data[0].to_int()
  let wire = data[3:].to_owned()
  let cut = ((data[1].to_int() << 8) | data[2].to_int()) % (wire.length() + 1)
  let response = (mode & 1) != 0
  let meth = methods[((mode >> 1) & 7) % methods.length()]
  let limits = if (mode & 16) != 0 {
    @h1.Limits::{
      max_head_bytes: 64,
      max_chunk_line_bytes: 8,
      max_trailer_bytes: 32,
      max_headers: 3,
    }
  } else {
    @h1.Limits::default()
  }
  let whole = read([wire], response, meth, limits) catch {
    e => abort("whole: unexpected error \{e}")
  }
  let split = read(
    [wire[:cut].to_owned(), wire[cut:].to_owned()],
    response,
    meth,
    limits,
  ) catch {
    e => abort("split: unexpected error \{e}")
  }
  if split != whole {
    abort("split at \{cut} differs: \{Repr(whole)} vs \{Repr(split)}")
  }
  if wire.length() <= 2048 {
    let bytes = read(
      Array::makei(wire.length(), i => wire[i:i + 1].to_owned()),
      response,
      meth,
      limits,
    ) catch {
      e => abort("bytes: unexpected error \{e}")
    }
    if bytes != whole {
      abort("byte by byte differs: \{Repr(whole)} vs \{Repr(bytes)}")
    }
  }
  match whole {
    Ok(message) => {
      rewrite(message, response, meth)
      1
    }
    Err(_) => 2
  }
}

///|
/// Writes the body back the way `framing` says.
fn encode_body(message : Message) -> Bytes {
  match message.framing {
    Length(_) | UntilClose => message.body
    Chunked => {
      let out = Buffer()
      if !message.body.is_empty() {
        out.write_bytes(@h1.encode_chunk(message.body))
      }
      out.write_bytes(b"0\r\n")
      for field in message.trailers.iter() {
        for c in field.0 {
          out.write_byte(c.to_int().to_byte())
        }
        out.write_bytes(b": ")
        for c in field.1 {
          out.write_byte(c.to_int().to_byte())
        }
        out.write_bytes(b"\r\n")
      }
      out.write_bytes(b"\r\n")
      out.to_bytes()
    }
    _ => b""
  }
}

///|
fn without_framing(headers : @mttp_core.Headers) -> @mttp_core.Headers {
  headers.remove("content-length").remove("transfer-encoding")
}

///|
/// What the reader accepts, the writer writes back and the reader reads
/// again with the same head, framing, body and trailers,
/// as property_test.mbt's rewrite_request and rewrite_response check.
fn rewrite(
  message : Message,
  response : Bool,
  meth : @mttp_core.Method,
) -> Unit {
  // The writer may add a field and a byte per field, in the head and in
  // trailers (property_test.mbt's read_back_limits), so a head or trailer
  // section at the default limits can come back over them: read it back
  // with room to spare.
  let limits = {
    ..@h1.Limits::default(),
    max_head_bytes: 65536,
    max_trailer_bytes: 65536,
    max_headers: 1000,
  }
  let body = encode_body(message)
  if response {
    let parsed = try! @h1.parse_response_head(message.head)
    // Readers keep 600-999 as failures; writers refuse them (h1 README).
    if parsed.status > 599 {
      return
    }
    let written = @h1.write_response_head(
      parsed.status,
      parsed.headers,
      message.framing,
      parsed.version,
      meth~,
    ) catch {
      e => abort("accepted response not written back: \{Repr(e)}")
    }
    let again = try! read([written, body], true, meth, limits)
    guard again is Ok(again) else {
      abort("written response refused: \{Repr(again)}")
    }
    let reparsed = try! @h1.parse_response_head(again.head, limits~)
    let fields = if message.framing == UntilClose {
      without_framing(parsed.headers).set("connection", "close")
    } else {
      without_framing(parsed.headers)
    }
    if reparsed.version != parsed.version ||
      reparsed.status != parsed.status ||
      without_framing(reparsed.headers) != fields ||
      again.framing != message.framing ||
      again.body != message.body ||
      again.trailers != message.trailers {
      abort("response rewrite differs: \{Repr(message)} vs \{Repr(again)}")
    }
  } else {
    let parsed = try! @h1.parse_request_head(message.head)
    let written = @h1.write_request_head(
      parsed.meth,
      parsed.target,
      parsed.headers,
      message.framing,
      parsed.version,
    ) catch {
      e => abort("accepted request not written back: \{Repr(e)}")
    }
    let again = try! read([written, body], false, meth, limits)
    guard again is Ok(again) else {
      abort("written request refused: \{Repr(again)}")
    }
    let reparsed = try! @h1.parse_request_head(again.head, limits~)
    let framing = if message.framing == NoBody &&
      parsed.meth is (Post | Put | Patch) {
      @h1.Framing::Length(0)
    } else {
      message.framing
    }
    if reparsed.meth != parsed.meth ||
      reparsed.target != parsed.target ||
      reparsed.version != parsed.version ||
      without_framing(reparsed.headers) != without_framing(parsed.headers) ||
      again.framing != framing ||
      again.body != message.body ||
      again.trailers != message.trailers ||
      again.rest != b"" {
      abort("request rewrite differs: \{Repr(message)} vs \{Repr(again)}")
    }
  }
}
