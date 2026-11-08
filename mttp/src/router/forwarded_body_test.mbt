///|
test "each middleware boundary closes replacement bodies on buffered short circuits" {
  let original = Ref(0)
  let first = Ref(0)
  let second = Ref(0)
  let replace_first : @router.Middleware = (req, next) => {
    next({ ..req, body: tracked(first), })
  }
  let replace_second : @router.Middleware = (req, next) => {
    next({ ..req, body: tracked(second), })
  }
  let reject : @router.Middleware = (_, _) => @http.Response::new(403)
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [replace_first, replace_second, reject],
  })
  @driver.run_sync(() => {
    assert_eq(
      router.dispatch({ ..@http.Request::post("/"), body: tracked(original), }).status,
      403,
    )
  })
  assert_eq(original.val, 1)
  assert_eq(first.val, 1)
  assert_eq(second.val, 1)
}

///|
test "cancelling a short circuit closes every forwarded replacement body" {
  let driver = @driver.Driver::new(auto_advance=false)
  let original = Ref(0)
  let forwarded = Ref(0)
  let entered = Ref(false)
  let replace : @router.Middleware = (req, next) => {
    next({ ..req, body: tracked(forwarded), })
  }
  let wait : @router.Middleware = (_, _) => {
    entered.val = true
    driver.sleep(10000)
    @http.Response::new(403)
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [replace, wait],
  })
  driver.run(() => {
    let task = driver.spawn(() => {
      ignore(
        router.dispatch({ ..@http.Request::post("/"), body: tracked(original), }),
      )
    })
    driver.pause()
    assert_true(entered.val)
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(original.val, 1)
  assert_eq(forwarded.val, 1)
}

///|
test "repeated next calls close every short circuited replacement body" {
  let closes = Ref(0)
  let replace : @router.Middleware = (req, next) => {
    ignore(next({ ..req, body: tracked(closes), }))
    next({ ..req, body: tracked(closes), })
  }
  let reject : @router.Middleware = (_, _) => @http.Response::new(204)
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [replace, reject],
  })
  @driver.run_sync(() => {
    assert_eq(router.dispatch(@http.Request::post("/")).status, 204)
  })
  assert_eq(closes.val, 2)
}

///|
test "lazy replacement request echoes remain live through EOF close and read failure" {
  for finish in ["eof", "close", "failure"] {
    let original = Ref(0)
    let forwarded = Ref(0)
    let replace : @router.Middleware = (req, next) => {
      next({ ..req, body: tracked(forwarded), })
    }
    let echo : @router.Middleware = (req, _) => {
      if finish == "failure" {
        @http.Response::new(
          200,
          body=Stream(@http.StreamBody::new(Failing::{ closes: Ref(0), })),
        )
      } else {
        @http.Response::new(200, body=req.body)
      }
    }
    let router = @router.Router::new([], options={
      ..@router.ServerOptions::default(),
      middleware: [replace, echo],
    })
    @driver.run_sync(() => {
      let response = router.dispatch({
        ..@http.Request::post("/"),
        body: tracked(original),
      })
      assert_eq(forwarded.val, 0)
      if finish == "eof" {
        assert_eq(@client.read_body(response.body, 10), b"body")
      } else if finish == "failure" {
        try ignore(@client.read_body(response.body, 10)) catch {
          @http.TransportError(_) => ()
        } noraise {
          _ => fail("expected read failure")
        }
      }
      response.close()
      assert_eq(original.val, 1)
      assert_eq(forwarded.val, 1)
    })
  }
}

///|
test "custom streamed rejections retain a forwarded request until the response closes" {
  let closes = Ref(0)
  let replace : @router.Middleware = (req, next) => {
    next({ ..req, body: tracked(closes), })
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [replace],
    reject: (req, _) => @http.Response::new(404, body=req.body),
  })
  @driver.run_sync(() => {
    let response = router.dispatch(@http.Request::post("/missing"))
    assert_eq(closes.val, 0)
    assert_eq(@client.read_body(response.body, 10), b"body")
    assert_eq(closes.val, 1)
  })
}
