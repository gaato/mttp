///|
async fn with_local_server(
  handler : @mttp.Handler,
  run : async (String) -> Unit,
) -> Unit {
  @async.with_timeout(10000, () => {
    @async.with_task_group(group => {
      let ready : Ref[String?] = Ref(None)
      let wake = @cond_var.Cond()
      group.spawn_bg(no_wait=true, () => {
        @server.serve(handler, addr="127.0.0.1:0", on_listen=address => {
          ready.val = Some(address)
          wake.signal()
        })
      })
      while ready.val is None {
        wake.wait()
      }
      run(ready.val.unwrap())
      group.return_immediately()
    })
  })
}

///|
async test "client() calls a JSON API, retrying a 503 once" {
  let calls = Ref(0)
  with_local_server(
    request => {
      calls.val += 1
      if calls.val == 1 {
        @mttp.Response::new(503)
      } else {
        @mttp.Response::new(
          200,
          headers=@mttp.Headers::of([("content-type", "application/json")]),
          body=Bytes(@utf8.encode("{\"id\": 1, \"path\": \"\{request.url}\"}")),
        )
      }
    },
    address => {
      let api = @mttp_async.client(base_url="http://\{address}")
      defer api.close()
      let reply = api.send(
        @mttp_async.get("/users/1").response(@mttp_async.as_json_value()),
      )
      assert_eq(reply.status, 200)
      assert_eq(calls.val, 2)
      match reply.body {
        // The server sees the absolute URL it rebuilt from the request.
        Ok(json) =>
          assert_eq(json, { "id": 1, "path": "http://\{address}/users/1" })
        Err(_) => fail("the JSON reply failed to decode")
      }
    },
  )
}

///|
async test "client() follows a redirect and turns retries off on request" {
  let calls = Ref(0)
  with_local_server(
    request => {
      calls.val += 1
      if request.url.has_suffix("/old") {
        @mttp.Response::new(
          301,
          headers=@mttp.Headers::of([("location", "/new")]),
        )
      } else {
        @mttp.Response::new(500)
      }
    },
    address => {
      let api = @mttp_async.client(
        base_url="http://\{address}",
        retry=@mttp_async.RetryPolicy::none(),
      )
      defer api.close()
      let reply = api.send(@mttp_async.get("/old"))
      assert_eq(reply.status, 500)
      assert_eq(calls.val, 2)
    },
  )
}

///|
async test "client(cookies=) sends a cookie set on a redirect to the next hop and later calls" {
  let seen : Array[String?] = []
  with_local_server(
    request => {
      seen.push(request.headers.get("cookie"))
      if request.url.has_suffix("/login") {
        @mttp.Response::new(
          302,
          headers=@mttp.Headers::of([
            ("location", "/home"),
            ("set-cookie", "session=abc; Path=/; HttpOnly"),
          ]),
        )
      } else {
        @mttp.Response::new(200)
      }
    },
    address => {
      let jar = @mttp_async.CookieJar::new(@mttp_async.clock())
      let site = @mttp_async.client(base_url="http://\{address}", cookies=jar)
      defer site.close()
      assert_eq(site.send(@mttp_async.get("/login")).status, 200)
      assert_eq(site.send(@mttp_async.get("/me")).status, 200)
      assert_eq(jar.length(), 1)
      // A second Client given the same jar sends it too.
      let other = @client.Client::new(
        @mttp_async.backend(cookies=jar),
        @mttp_async.clock(),
        base_url="http://\{address}",
      )
      defer other.close()
      assert_eq(other.send(@mttp_async.get("/again")).status, 200)
    },
  )
  assert_eq(seen, [
    None,
    Some("session=abc"),
    Some("session=abc"),
    Some("session=abc"),
  ])
}

///|
async test "backend(), clock() and timer() give a hand-built Client a total deadline" {
  with_local_server(
    request => {
      if request.url.has_suffix("/slow") {
        @async.sleep(2000)
      }
      @mttp.Response::new(200, body=Bytes(b"ok"))
    },
    address => {
      let api = @client.Client::new(
        @mttp_async.backend(),
        @mttp_async.clock(),
        timer=@mttp_async.timer(),
        base_url="http://\{address}",
        total_ms=200,
        retry=@client.RetryPolicy::none(),
      )
      defer api.close()
      let fast = api.send(@mttp_async.get("/fast"))
      assert_eq(fast.body, Ok("ok"))
      let kind = try {
        ignore(api.send(@mttp_async.get("/slow")))
        None
      } catch {
        @mttp.TransportError(kind~, ..) => Some(kind)
        _ => None
      }
      assert_true(kind is Some(Timeout(..)))
    },
  )
}

///|
async test "coordination() lets an EventStream channel wait on the event loop" {
  let (sender, stream) = @endpoint.EventStream::channel(
    coordination=@mttp_async.coordination(),
    capacity=1,
  )
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      assert_true(sender.send(1))
      assert_true(sender.send(2))
      sender.close()
    })
    assert_eq(stream.next(), Some(1))
    assert_eq(stream.next(), Some(2))
    assert_eq(stream.next(), None)
  })
}
