///|
/// What a sans-IO reader built on the codec made of one message: its head,
/// framing, payload, trailers and the bytes left for the next message.
#derive(Eq, Debug)
struct Message {
  head : Bytes
  framing : @h1.Framing
  body : Bytes
  trailers : @mttp_core.Headers
  rest : Bytes
}

///|
/// Reads one message from `pieces` the way a connection engine does: the
/// head through `HeadDecoder` (skipping empty lines before a request), the framing from `framing`, then the body
/// through `ChunkedDecoder` or by length. Piece boundaries are kept all the
/// way, so the result depends on them only if the codec does.
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
/// Reads a request the way the server engine does.
fn read_request(
  pieces : Array[Bytes],
  limits~ : @h1.Limits = @h1.Limits::default(),
) -> Result[Message, @h1.ParseKind] raise {
  read_message(pieces, limits, skip_leading_crlf=true, head => {
    @h1.request_framing(@h1.parse_request_head(head, limits~).headers)
  })
}

///|
/// Reads a response to `meth` the way the client engine does.
fn read_response(
  pieces : Array[Bytes],
  meth~ : @mttp_core.Method = Get,
  limits~ : @h1.Limits = @h1.Limits::default(),
) -> Result[Message, @h1.ParseKind] raise {
  read_message(pieces, limits, skip_leading_crlf=false, head => {
    let response = @h1.parse_response_head(head, limits~)
    @h1.response_framing(response.headers, status=response.status, meth~)
  })
}

///|
/// The kind `wire` is refused with, whole and at every split.
fn request_refusal(
  wire : Bytes,
  limits~ : @h1.Limits = @h1.Limits::default(),
) -> @h1.ParseKind? raise {
  match check_splits(wire, pieces => read_request(pieces, limits~)) {
    Err(kind) => Some(kind)
    Ok(_) => None
  }
}

///|
/// The kind a response to `meth` is refused with, whole and at every split.
fn response_refusal(
  wire : Bytes,
  meth~ : @mttp_core.Method = Get,
) -> @h1.ParseKind? raise {
  match check_splits(wire, pieces => read_response(pieces, meth~)) {
    Err(kind) => Some(kind)
    Ok(_) => None
  }
}
