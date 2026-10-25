///|
priv struct Tracked {
  closes : Ref[Int32]
  mut closed : Bool
  mut sent : Bool
}

///|
impl @model.BodyStream for Tracked with fn read_some(self) {
  if self.closed || self.sent {
    return None
  }
  self.sent = true
  Some(b"body")
}

///|
impl @model.BodyStream for Tracked with fn close(self) {
  if !self.closed {
    self.closed = true
    self.closes.val += 1
  }
}

///|
fn tracked(closes : Ref[Int32]) -> @model.Body {
  @model.Stream(
    @model.StreamBody::new(Tracked::{ closes, closed: false, sent: false, }),
  )
}

///|
priv struct Failing {
  closes : Ref[Int32]
}

///|
impl @model.BodyStream for Failing with fn read_some(_) {
  raise @model.TransportError(
    kind=Network,
    phase=Body,
    detail="producer failed",
  )
}

///|
impl @model.BodyStream for Failing with fn close(self) {
  self.closes.val += 1
}

///|
test "middleware response read failures close both response and original request" {
  let input = Ref(0)
  let output = Ref(0)
  let middleware : @router.Middleware = (_, _) => {
    @model.Response::new(
      200,
      body=Stream(@model.StreamBody::new(Failing::{ closes: output, })),
    )
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [middleware],
  })
  @driver.run_sync(() => {
    let response = router.dispatch({
      ..@model.Request::post("/"),
      body: tracked(input),
    })
    let failed = try {
      ignore(@client.read_body(response.body, 32))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    response.close()
    assert_eq(input.val, 1)
    assert_eq(output.val, 1)
  })
}

///|
test "middleware keeps lazy request echoes alive and closes replaced responses" {
  let closes = Ref(0)
  let echo : @router.Middleware = (request, _) => {
    @model.Response::new(200, body=request.body)
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [echo],
  })
  @driver.run_sync(() => {
    let response = router.handler()({
      ..@model.Request::post("/"),
      body: tracked(closes),
    })
    assert_eq(closes.val, 0)
    assert_eq(@client.read_body(response.body, 32), b"body")
    response.close()
    assert_eq(closes.val, 1)
  })
  let outer : @router.Middleware = (request, next) => {
    ignore(next(request))
    @model.Response::new(204)
  }
  let inner : @router.Middleware = (_, _) => {
    @model.Response::new(200, body=tracked(closes))
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [outer, inner],
  })
  @driver.run_sync(() => {
    assert_eq(router.dispatch(@model.Request::get("/")).status, 204)
  })
  assert_eq(closes.val, 2)
}

///|
test "cancelling middleware closes a response obtained from next" {
  let driver = @driver.Driver::new(auto_advance=false)
  let closes = Ref(0)
  let inner : @router.Middleware = (_, _) => {
    @model.Response::new(200, body=tracked(closes))
  }
  let entered = Ref(false)
  let outer : @router.Middleware = (request, next) => {
    let response = next(request)
    entered.val = true
    driver.sleep(10000)
    response
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [outer, inner],
  })
  driver.run(() => {
    let task = driver.spawn(() => {
      ignore(router.dispatch(@model.Request::get("/")))
    })
    driver.pause()
    assert_true(entered.val)
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(closes.val, 1)
}

///|
test "router rejection and closed state close an unread request body" {
  let closes = Ref(0)
  let router = @router.Router::new([])
  @driver.run_sync(() => {
    assert_eq(
      router.dispatch({ ..@model.Request::get("/"), body: tracked(closes), }).status,
      404,
    )
    router.close()
    assert_eq(
      router.dispatch({ ..@model.Request::get("/"), body: tracked(closes), }).status,
      503,
    )
  })
  assert_eq(closes.val, 2)
}

///|
test "calling middleware next again closes the previous streamed result" {
  let closes = Ref(0)
  let inner : @router.Middleware = (_, _) => {
    @model.Response::new(200, body=tracked(closes))
  }
  let outer : @router.Middleware = (request, next) => {
    ignore(next(request))
    next(request)
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [outer, inner],
  })
  @driver.run_sync(() => {
    let response = router.dispatch(@model.Request::get("/"))
    assert_eq(closes.val, 1)
    response.close()
    assert_eq(closes.val, 2)
  })
}

///|
test "middleware cannot return an already consumed response stream" {
  let closes = Ref(0)
  let middleware : @router.Middleware = (_, _) => {
    let body = tracked(closes)
    if body is Stream(stream) {
      ignore(stream.take() catch { _ => return @model.Response::new(500) })
    }
    @model.Response::new(200, body~)
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [middleware],
  })
  @driver.run_sync(() => {
    assert_eq(router.dispatch(@model.Request::get("/")).status, 500)
  })
  assert_eq(closes.val, 1)
}
