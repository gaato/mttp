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
