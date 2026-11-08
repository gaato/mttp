// Writing a request and reading its final response head. A body that fits
// in the first write goes out with the head; a larger one is uploaded while
// the response head is read, so a response that arrives early ends the
// upload (the server refused it, or answered without needing it) and the
// connection is not reused.

///|
/// What one exchange produced: the final response head, and whether the
/// whole request was sent, without which the connection cannot be reused.
priv struct Exchanged {
  head : @h1.ParsedResponse
  uploaded : Bool
}

///|
/// A request body as the exchange sends it: in memory, or a stream already
/// taken with its first piece read.
priv enum Upload {
  Bytes(Bytes)
  Stream(&@http.BodyStream, Bytes?)
}

///|
/// The first write carries the head and, when they fit in one write, the
/// body bytes; otherwise the exchange uploads concurrently.
async fn exchange(
  wire : Wire,
  head : Bytes,
  upload : Upload,
  framing : @h1.Framing,
  timer : PhaseTimer,
  limits : @h1.Limits,
  coordination : &@rt.Coordination,
) -> Exchanged raise @http.TransportError {
  match upload {
    Bytes(bytes) if head.length() + bytes.length() <= io_bytes => {
      timer.run(Write, () => wire.write(head + bytes))
      { head: timer.run(Head, () => final_head(wire, limits)), uploaded: true, }
    }
    Stream(_, None) => {
      // An empty stream: the head, and the last chunk when chunked.
      let last = if framing is Chunked { @h1.encode_chunk(b"") } else { b"" }
      timer.run(Write, () => wire.write(head + last))
      { head: timer.run(Head, () => final_head(wire, limits)), uploaded: true, }
    }
    _ => duplex(wire, head, upload, framing, timer, limits, coordination)
  }
}

///|
/// The payload of one stream piece as `framing` puts it on the wire.
fn frame(bytes : Bytes, framing : @h1.Framing) -> Bytes {
  if framing is Chunked {
    @h1.encode_chunk(bytes)
  } else {
    bytes
  }
}

///|
/// Sends the head and the body. The head goes out with the first piece; a
/// stream is read under the Write limit and written piece by piece, never
/// holding more than one piece.
async fn upload(
  wire : Wire,
  head : Bytes,
  upload : Upload,
  framing : @h1.Framing,
  timer : PhaseTimer,
) -> Unit raise @http.TransportError {
  match upload {
    Bytes(bytes) => {
      let first = (io_bytes - head.length()).max(0).min(bytes.length())
      timer.run(Write, () => wire.write(head + bytes[:first].to_owned()))
      wire.send(bytes[first:], timer)
    }
    Stream(stream, first) => {
      let mut prefix = head
      let mut next = first
      while next is Some(bytes) {
        let data = frame(bytes, framing)
        if prefix.length() + data.length() <= io_bytes {
          timer.run(Write, () => wire.write(prefix + data))
        } else {
          wire.send(prefix, timer)
          wire.send(data, timer)
        }
        prefix = b""
        next = timer.run(Write, () => stream.read_some())
      }
      let last = if framing is Chunked { @h1.encode_chunk(b"") } else { b"" }
      wire.send(prefix + last, timer)
    }
  }
}

///|
/// Reads response heads until a final one: 1xx heads other than 101 are
/// skipped, at most 16 of them.
async fn final_head(
  wire : Wire,
  limits : @h1.Limits,
) -> @h1.ParsedResponse raise @http.TransportError {
  for _ in 0..<17 {
    let head = wire.head(limits)
    if head.status >= 200 || head.status == 101 {
      return head
    }
  }
  raise @http.TransportError(
    kind=Protocol,
    phase=Head,
    detail="too many informational responses",
  )
}

///|
/// The two halves of a concurrent exchange, as each finished.
priv struct Duplex {
  mut head : Result[@h1.ParsedResponse, @http.TransportError]?
  mut sent : Result[Unit, @http.TransportError]?
  changed : &@rt.Signal
  head_ready : &@rt.Signal
}

///|
/// Uploads while reading the response head. The upload is the monitor of
/// the exchange, so a final head that arrives first ends it by cancellation.
/// A network failure of the upload may be the server closing after an
/// early answer, so the head is still awaited; a producer failure is not
/// made valid by any answer and fails the exchange. The head limit starts
/// once the upload is done: a long upload is bounded by its writes.
async fn duplex(
  wire : Wire,
  head : Bytes,
  body : Upload,
  framing : @h1.Framing,
  timer : PhaseTimer,
  limits : @h1.Limits,
  coordination : &@rt.Coordination,
) -> Exchanged raise @http.TransportError {
  let state = Duplex::{
    head: None,
    sent: None,
    changed: coordination.signal(),
    head_ready: coordination.signal(),
  }
  // Whether the upload had finished when the final head was taken.
  let mut uploaded = false
  coordination.supervise(
    monitor=() => {
      // Both halves store failures with their phase, as the one-write path
      // reports them, so a failure does not depend on the body's size.
      state.sent = Some(
        Ok(upload(wire, head, body, framing, timer)) catch {
          error => Err(failure(Write, error))
        },
      )
      state.changed.notify()
    },
    primary=() => {
      coordination.supervise(
        monitor=() => {
          state.head = Some(
            Ok(final_head(wire, limits)) catch {
              error => Err(failure(Head, error))
            },
          )
          state.head_ready.notify()
          state.changed.notify()
        },
        primary=() => {
          while state.head is None && state.sent is None {
            state.changed.wait()
          }
          if state.sent is Some(Err(error)) && !(kind_of(error) is Network) {
            raise error
          }
          if state.head is None {
            timer.run(Head, () => {
              while state.head is None {
                state.head_ready.wait()
              }
            }) catch {
              error => raise state.reported(error)
            }
          }
          if state.head is Some(Err(error)) {
            raise state.reported(error)
          }
          uploaded = state.sent is Some(Ok(_))
        },
      )
    },
  )
  // The primary returns only once a final head arrived.
  guard state.head is Some(Ok(response)) else {
    raise @http.TransportError(
      kind=Protocol,
      phase=Head,
      detail="the exchange ended without a response head",
    )
  }
  { head: response, uploaded, }
}

///|
/// The failure to report for `error`: the upload's own network failure
/// when it had one, since the read failed only because the peer went.
fn Duplex::reported(
  self : Duplex,
  error : @http.TransportError,
) -> @http.TransportError {
  match self.sent {
    Some(Err(write_error)) => write_error
    _ => error
  }
}

///|
fn kind_of(error : @http.TransportError) -> @http.Kind {
  let @http.TransportError(kind~, ..) = error
  kind
}
