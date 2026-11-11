// Reading the next request head under the header deadline, and the status
// each failure is answered with.

///|
/// How reading the next request head ended.
priv enum HeadOutcome {
  /// A request head, parsed and validated.
  Request(@h1.ParsedRequest)
  /// The peer ended its stream, or the header deadline ran out, before a
  /// byte of a request arrived: the connection closes without an answer.
  Idle
  /// The head is refused: answer with `status` and close.
  Refuse(status~ : Int32, error~ : @mttp.TransportError)
  /// Reading failed: close without an answer.
  Lost(@mttp.TransportError)
}

///|
/// Reads the next request head within `header_timeout_ms`. Empty lines
/// before a request line are skipped (RFC 9112, section 2.2) and count
/// against `max_header_bytes`. Bytes after the head stay pending.
async fn Wire::head(self : Wire, limits : ServerLimits) -> HeadOutcome noraise {
  let mut started = !self.pending.is_empty()
  let mut outcome = Idle
  let completed = self.timer.within(limits.header_timeout_ms, () => {
    let decoder = @h1.HeadDecoder::new(
      max=limits.max_header_bytes,
      skip_leading_crlf=true,
    )
    outcome = for ;; {
      let bytes = self.read(io_bytes, Head) catch { error => break Lost(error) }
      guard bytes is Some(bytes) else {
        break if started {
          refuse_head(
            @h1.ParseError(kind=Malformed, detail="truncated request head"),
            limits,
          )
        } else {
          Idle
        }
      }
      started = true
      let result = decoder.feed(bytes) catch {
        error => break refuse_head(error, limits)
      }
      if result.head is Some(head) {
        self.unread(bytes[result.consumed:])
        break try
          @h1.parse_request_head(head, limits={
            ..@h1.Limits::default(),
            max_head_bytes: limits.max_header_bytes,
          })
        catch {
          error => refuse_head(error, limits)
        } noraise {
          request => Request(request)
        }
      }
    }
  })
  if completed {
    outcome
  } else if started {
    Refuse(
      status=408,
      error=timeout(limits.header_timeout_ms, Head, "the request head"),
    )
  } else {
    Idle
  }
}

///|
/// The answer to a head the codec refused: 431 for a head past its limits,
/// 505 for an HTTP version other than 1.x, 400 otherwise (smuggling
/// included).
fn refuse_head(error : @h1.ParseError, limits : ServerLimits) -> HeadOutcome {
  let @h1.ParseError(kind~, detail~) = error
  match kind {
    HeadTooLarge =>
      Refuse(
        status=431,
        error=@mttp.TransportError(
          kind=TooLarge(limit=limits.max_header_bytes),
          phase=Head,
          detail~,
        ),
      )
    Unsupported =>
      Refuse(
        status=505,
        error=@mttp.TransportError(kind=Protocol, phase=Head, detail~),
      )
    _ =>
      Refuse(
        status=400,
        error=@mttp.TransportError(kind=Protocol, phase=Head, detail~),
      )
  }
}

///|
/// The status for a body framing the codec refused: 501 for a transfer
/// coding other than a single `chunked`, 400 for smuggling (CL with TE) and
/// for a duplicate or invalid Content-Length.
fn framing_status(kind : @h1.ParseKind) -> Int32 {
  match kind {
    Unsupported => 501
    _ => 400
  }
}

///|
/// The status that answers a request body failure: 413 past the body limit,
/// 408 past its deadline, 400 for anything else (bad chunk framing, a chunk
/// line or trailers past their limits, early EOF).
fn body_status(error : @mttp.TransportError) -> Int32 {
  match error {
    @mttp.TransportError(kind=TooLarge(..), ..) => 413
    @mttp.TransportError(kind=Timeout(..), ..) => 408
    _ => 400
  }
}
