// The HTTP/2 server target: a server session fed what a client sent, cut
// in pieces of a fuzzer-chosen size, answering each request it reads, as
// h2server's reader and writer drive one. The invariants: no crash and no
// memory error in nghttp2 or h2_stub.c (ASan); every header block handed
// on keeps within the header list bound, counted as h2_stub.c counts it;
// and a stream's DATA comes after its request's head.
//
// The input: a mode byte (bit 0: a small header list bound; bit 1: small
// windows; bit 2: answer with a body; bit 3: take the body bytes at once),
// a piece size byte, then the client's bytes.

///|
/// The server's settings for `mode`.
fn server_settings(mode : Int32) -> @h2.H2Settings {
  let settings = @h2.H2Settings::server()
  let settings = if (mode & 1) != 0 {
    { ..settings, max_header_list: 200, }
  } else {
    settings
  }
  if (mode & 2) != 0 {
    { ..settings, stream_window: 100, connection_window: 300, low_mark: 50, }
  } else {
    settings
  }
}

///|
/// The size of a header block as h2_stub.c bounds it.
fn block_size(fields : Array[(String, String)]) -> Int32 {
  fields.fold(init=0, (n, field) => n + field.0.length() + field.1.length() + 32)
}

///|
pub fn fuzz_h2_server(data : Bytes) -> Int32 {
  let input = Input::new(data)
  let mode = input.byte()
  let piece = input.byte() + 1
  let settings = server_settings(mode)
  let session = @h2.H2Session::server(settings~) catch {
    _ => abort("no server session")
  }
  defer session.free()
  let heads : Map[Int32, Unit] = Map([])
  let rest = input.rest()
  for at = 0; at < rest.length(); at = at + piece {
    let end = (at + piece).min(rest.length())
    let failed = try {
      session.recv(rest[at:end].to_owned())
      false
    } catch {
      @h2.H2Error(..) => true
    }
    for event in session.events() {
      match event {
        Headers(stream~, kind=Request, fields~, ..) => {
          if block_size(fields) > settings.max_header_list {
            abort("a header block over the bound was handed on")
          }
          heads[stream] = ()
          session.submit_response(
            stream,
            [(":status", "200")],
            body=(mode & 4) != 0,
          ) catch {
            _ => ()
          }
          if (mode & 4) != 0 {
            session.push(stream, b"answer", end=true) catch {
              _ => ()
            }
          }
        }
        Headers(fields~, ..) =>
          if block_size(fields) > settings.max_header_list {
            abort("a header block over the bound was handed on")
          }
        Data(stream~, bytes) => {
          if !heads.contains(stream) {
            abort("DATA of stream \{stream} before its head")
          }
          session.consume_connection(bytes.length())
          if (mode & 8) != 0 {
            session.consume_stream(stream, bytes.length())
          }
        }
        _ => ()
      }
    }
    // What the session has to say, as the writer takes it, and what
    // taking it caused.
    ignore(session.output())
    ignore(session.events())
    if failed {
      break
    }
  }
  0
}
