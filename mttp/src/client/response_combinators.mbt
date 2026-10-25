///|
/// Buffers and decodes form pairs with the model's forgiving UTF-8 and
/// percent decoding. Both max_body_bytes and max_pairs apply.
pub fn as_form(max_pairs~ : Int32 = 256) -> ResponseAs[Array[(String, String)]] {
  as_string().map(text => @model.form_urldecode(text, max_pairs~))
}

///|
/// Buffers once within max_body_bytes, then reads the same immutable bytes
/// with both interpretations, left first. Both must accept the head; if not,
/// the first rejecting interpretation handles the bounded error excerpt.
/// Selectors run once each. This combinator runs inside the attempt even
/// when either input is a streaming interpretation.
pub fn[A, B] as_both(
  left : ResponseAs[A],
  right : ResponseAs[B],
) -> ResponseAs[(A, B)] {
  {
    streaming: false,
    select: head => {
      let a = (left.select)(head)
      let b = (right.select)(head)
      {
        streaming: false,
        accept: a.accept && b.accept,
        reject: if !a.accept {
          a.reject
        } else {
          b.reject
        },
        read: (head, body, options) => {
          let bytes = read_body(body, options.max_body_bytes)
          let first = (a.read)(head, Bytes(bytes), options)
          let second = (b.read)(head, Bytes(bytes), options)
          (first, second)
        },
      }
    },
  }
}

///|
/// Streams LF-separated UTF-8 lines, stripping CR in CRLF and replacing
/// malformed UTF-8. A final nonempty unterminated line is delivered; a lone
/// CR is data. Limits content bytes per line (default one MiB), retaining
/// at most that limit plus a pending CR. Callback errors close the body and
/// never retry an already-delivered stream.
pub fn as_lines(
  receive : async (String) -> Unit,
  max_line_bytes~ : Int32 = 1024 * 1024,
) -> ResponseAs[Unit] {
  as_stream((_, stream) => {
    if max_line_bytes < 0 {
      raise @model.TransportError(
        kind=Invalid,
        phase=Body,
        detail="negative line limit",
      )
    }
    let line = Buffer()
    let mut pending_cr = false
    fn append(byte : Byte) -> Unit raise @model.TransportError {
      if line.length() >= max_line_bytes {
        raise @model.TransportError(
          kind=TooLarge(limit=max_line_bytes),
          phase=Body,
          detail="line exceeds limit",
        )
      }
      line.write_byte(byte)
    }
    while stream.read_some() is Some(chunk) {
      for byte in chunk {
        if byte == b'\n' {
          receive(@utf8.decode_lossy(line.to_bytes()))
          line.reset()
          pending_cr = false
        } else {
          if pending_cr {
            append(b'\r')
          }
          pending_cr = byte == b'\r'
          if !pending_cr {
            append(byte)
          }
        }
      }
    }
    if pending_cr {
      append(b'\r')
    }
    if !line.is_empty() {
      receive(@utf8.decode_lossy(line.to_bytes()))
    }
  })
}
