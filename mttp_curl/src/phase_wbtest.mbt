///|
/// The phase events a send reports, as text.
async fn events_of(
  backend : CurlBackend,
  request : @mttp_core.Request,
) -> Array[String] {
  let seen = []
  let request = {
    ..request,
    attributes: request.attributes.put(@mttp_core.on_phase, event => {
      seen.push(
        match event {
          Dialed(addr~) => "Dialed(\{addr})"
          TlsDone => "TlsDone"
          Pooled(reused~) => "Pooled(\{reused})"
          Written => "Written"
          FirstByte => "FirstByte"
          @mttp_core.PhaseEvent::.. => "other"
        },
      )
    }),
  }
  let response = backend.send(request, @mttp_core.SendOptions::default()) catch {
    _ => return seen
  }
  response.body.read_all(max=1 << 20) |> ignore
  seen
}

///|
/// `Written`, where the linked libcurl can tell.
fn written() -> Array[String] {
  if knows_when_sent() {
    ["Written"]
  } else {
    []
  }
}

///|
async test "phase events of a new and of a reused connection" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let port = server.h2c.split(":").last().unwrap().to_owned()
    let first = events_of(
      backend,
      @mttp_core.Request::get(server.h2c + "/hello"),
    )
    assert_eq(
      first,
      ["Dialed(127.0.0.1:\{port})", "Pooled(false)", ..written(), "FirstByte"],
    )
    let second = events_of(
      backend,
      @mttp_core.Request::get(server.h2c + "/hello"),
    )
    assert_eq(second, ["Pooled(true)", ..written(), "FirstByte"])
  })
}

///|
async test "phase events over TLS include TlsDone" {
  with_server(server => {
    let backend = tls_backend()
    defer backend.close()
    let port = server.tls.split(":").last().unwrap().to_owned()
    let events = events_of(
      backend,
      @mttp_core.Request::get(server.tls + "/hello"),
    )
    assert_eq(
      events,
      [
        "Dialed(localhost:\{port})",
        "TlsDone",
        "Pooled(false)",
        ..written(),
        "FirstByte",
      ],
    )
  })
}

///|
async test "a refused connection reports no phase event" {
  let backend = h2c_backend()
  defer backend.close()
  let events = events_of(
    backend,
    @mttp_core.Request::get("http://127.0.0.1:1/"),
  )
  assert_eq(events, [])
}
