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
  Stream(&@mttp.BodyStream, Bytes?)
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
) -> Exchanged raise @mttp.TransportError {
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
/// holding more than one piece. A failure of the stream itself is raised
/// as `ProducerFailed`, every other failure as it is.
async fn upload(
  wire : Wire,
  head : Bytes,
  upload : Upload,
  framing : @h1.Framing,
  timer : PhaseTimer,
) -> Unit {
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
        next = timer.run(Write, () => stream.read_some()) catch {
          error => raise ProducerFailed(error)
        }
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
) -> @h1.ParsedResponse raise @mttp.TransportError {
  for _ in 0..<17 {
    let head = wire.head(limits)
    if head.status >= 200 || head.status == 101 {
      return head
    }
  }
  raise @mttp.TransportError(
    kind=Protocol,
    phase=Head,
    detail="too many informational responses",
  )
}

///|
/// A request body stream that failed while it was uploaded, with its own
/// error.
priv suberror ProducerFailed {
  ProducerFailed(@mttp.TransportError)
}

///|
/// Why an upload ended early: its body stream failed, or the connection.
priv enum UploadFailure {
  Producer(@mttp.TransportError)
  Connection(@mttp.TransportError)
}

///|
/// The two halves of a concurrent exchange, as each finished.
priv struct Duplex {
  mut head : Result[@h1.ParsedResponse, @mttp.TransportError]?
  mut sent : Result[Unit, UploadFailure]?
  changed : &@rt.Signal
  head_ready : &@rt.Signal
}

///|
/// Uploads while reading the response head. The upload is the monitor of
/// the exchange, so a final head that arrives first ends it by cancellation.
/// A network failure of a connection write may be the server closing after
/// an early answer, so the head is still awaited. A failure of the body
/// stream fails the exchange at once with the stream's own error, whatever
/// it is: the request on the wire is incomplete, so no answer can be
/// expected, and none would make it valid. The head limit starts once the
/// upload is done: a long upload is bounded by its writes.
async fn duplex(
  wire : Wire,
  head : Bytes,
  body : Upload,
  framing : @h1.Framing,
  timer : PhaseTimer,
  limits : @h1.Limits,
  coordination : &@rt.Coordination,
) -> Exchanged raise @mttp.TransportError {
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
          ProducerFailed(error) => Err(Producer(error))
          error => Err(Connection(failure(Write, error)))
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
          match state.sent {
            Some(Err(Producer(error))) => raise error
            Some(Err(Connection(error))) if !(kind_of(error) is Network) =>
              raise error
            _ => ()
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
    raise @mttp.TransportError(
      kind=Protocol,
      phase=Head,
      detail="the exchange ended without a response head",
    )
  }
  { head: response, uploaded, }
}

///|
/// The failure to report for `error`: the upload's own connection failure
/// when it had one, since the read failed only because the peer went.
fn Duplex::reported(
  self : Duplex,
  error : @mttp.TransportError,
) -> @mttp.TransportError {
  match self.sent {
    Some(Err(Connection(write_error))) => write_error
    _ => error
  }
}

///|
fn kind_of(error : @mttp.TransportError) -> @mttp.Kind {
  let @mttp.TransportError(kind~, ..) = error
  kind
}
