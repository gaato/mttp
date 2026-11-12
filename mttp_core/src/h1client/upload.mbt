// Writing a request and reading its final response head. A body that fits
// in the first write goes out with the head; a larger one is uploaded while
// the response head is read, so a response that arrives early ends the
// upload (the server refused it, or answered without needing it) and the
// connection is not reused. A request that asks `Expect: 100-continue`
// sends its head alone and its body only after the server's 100, or after
// `continue_wait_ms` without an answer.

///|
/// How long a request with `Expect: 100-continue` waits for the server's
/// 100 before it sends its body anyway (RFC 9110, section 10.1.1, lets a
/// client stop waiting); curl and Go's net/http wait one second too. A final
/// answer that comes first, such as a 413, ends the exchange with the body
/// unsent. Sending at once instead let a server that refuses the body close
/// the connection while it was still arriving, and the reset that follows
/// can destroy its answer before the client reads it (seen with Apache over
/// TLS).
let continue_wait_ms : Int32 = 1000

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
  Stream(&@mttp_core.BodyStream, Bytes?)
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
  expect_continue~ : Bool = false,
) -> Exchanged raise @mttp_core.TransportError {
  let has_body = match upload {
    Bytes(bytes) => !bytes.is_empty()
    Stream(_, first) => first is Some(_)
  }
  match upload {
    _ if expect_continue && has_body =>
      duplex(
        wire,
        head,
        upload,
        framing,
        timer,
        limits,
        coordination,
        expect_continue=true,
      )
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
    _ =>
      duplex(
        wire,
        head,
        upload,
        framing,
        timer,
        limits,
        coordination,
        expect_continue=false,
      )
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
  before_body? : async () -> Unit,
) -> Unit {
  // With `before_body`, the head goes out alone and the body after it.
  let head = match before_body {
    Some(wait) => {
      wire.send(head, timer)
      wait()
      b""
    }
    None => head
  }
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
/// skipped, at most 16 of them; `on_continue` hears each 100.
async fn final_head(
  wire : Wire,
  limits : @h1.Limits,
  on_continue? : () -> Unit,
) -> @h1.ParsedResponse raise @mttp_core.TransportError {
  for _ in 0..<17 {
    let head = wire.head(limits)
    if head.status >= 200 || head.status == 101 {
      return head
    }
    if head.status == 100 && on_continue is Some(heard) {
      heard()
    }
  }
  raise @mttp_core.TransportError(
    kind=Protocol,
    phase=Head,
    detail="too many informational responses",
  )
}

///|
/// A request body stream that failed while it was uploaded, with its own
/// error.
priv suberror ProducerFailed {
  ProducerFailed(@mttp_core.TransportError)
}

///|
/// Why an upload ended early: its body stream failed, or the connection.
priv enum UploadFailure {
  Producer(@mttp_core.TransportError)
  Connection(@mttp_core.TransportError)
}

///|
/// The two halves of a concurrent exchange, as each finished.
priv struct Duplex {
  mut head : Result[@h1.ParsedResponse, @mttp_core.TransportError]?
  mut sent : Result[Unit, UploadFailure]?
  changed : &@rt.Signal
  head_ready : &@rt.Signal
}

///|
/// Uploads while reading the response head. The upload is the monitor of
/// the exchange, so a final head that arrives first ends it by cancellation.
/// A network failure of a connection write may be the server closing after
/// an early answer, so the head is still awaited, unless the write was
/// refused before any of the request left: then no head can answer it. A
/// failure of the body
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
  expect_continue~ : Bool,
) -> Exchanged raise @mttp_core.TransportError {
  let continued = coordination.signal()
  // Waits for the 100, at most `continue_wait_ms` and never past the
  // attempt's deadline; a final head first ends the upload by cancellation.
  let before_body : (async () -> Unit)? = if expect_continue {
    Some(async fn() {
      let wait = match timer.remaining() {
        Some(left) => left.min(continue_wait_ms.to_int64()).to_int()
        None => continue_wait_ms
      }
      let _ = timer.timer.within(wait, () => continued.wait())
    })
  } else {
    None
  }
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
        Ok(upload(wire, head, body, framing, timer, before_body?)) catch {
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
            Ok(final_head(wire, limits, on_continue=() => continued.notify())) catch {
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
          // A head can answer this request only if some of it was sent.
          match state.sent {
            Some(Err(Producer(error))) => raise error
            Some(Err(Connection(error))) if !(kind_of(error) is Network) ||
              wire.refused => raise error
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
    raise @mttp_core.TransportError(
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
  error : @mttp_core.TransportError,
) -> @mttp_core.TransportError {
  match self.sent {
    Some(Err(Connection(write_error))) => write_error
    _ => error
  }
}

///|
fn kind_of(error : @mttp_core.TransportError) -> @mttp_core.Kind {
  let @mttp_core.TransportError(kind~, ..) = error
  kind
}
