///|
/// A server that answers 503 to the first two requests and 200 after that.
fn flaky() -> @mttp.Handler {
  let served = Ref(0)
  _ => {
    served.val += 1
    if served.val <= 2 {
      @mttp.Response::new(503)
    } else {
      @mttp.Response::new(200, body=Bytes(b"ready"))
    }
  }
}

///|
/// Calls `addr` with the retry policy `@mttp.client()` uses by default
/// and prints every attempt the Client makes.
async fn call(addr : String) -> Unit {
  let client = @mttp.Client::new(
    @mttp.backend(),
    @mttp.clock(),
    timer=@mttp.timer(),
    base_url="http://\{addr}",
    retry=@mttp.RetryPolicy::conservative(),
    // The policy spreads each wait by up to 20 % either way; the middle of
    // that range keeps this output the same on every run.
    random=() => 0.5,
    observer=attempt => {
      let next = match attempt.decision {
        Some(Wait(ms)) => "retry in \{ms} ms"
        Some(_) => "give up"
        None => "done"
      }
      println("attempt \{attempt.attempt + 1}: \{attempt.status}, \{next}")
    },
  )
  defer client.close()
  let reply = client.send(@mttp.get("/status"))
  match reply.body {
    Ok(text) => println("result: \{reply.status} \{text}")
    Err(failure) => println("result: \{failure}")
  }
}

///|
fn main {
  @mttp.run(async fn() {
    @async.with_task_group(group => {
      @server.serve(flaky(), addr="127.0.0.1:0", on_listen=addr => {
        group.spawn_bg(() => {
          call(addr)
          group.return_immediately()
        })
      })
    })
  })
}
