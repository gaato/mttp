///|
async fn exercise(base : String) -> Unit {
  let expected : (String, Json) = ("hello", { "name": "Ada" })
  assert_eq(get_before(base), expected)
  assert_eq(get_after(base), expected)
  println("GET: text and JSON agree")
  assert_eq(post_before(base), post_after(base))
  println("POST: JSON echo agrees")
  assert_eq(timeout_before(base), "hello")
  assert_eq(timeout_after(base), "hello")
  println("timeout: successful calls agree")
  assert_eq(reuse_before(base), "hello, hello")
  assert_eq(reuse_after(base), "hello, hello")
  println("reuse: two calls agree")
  assert_eq(errors_before(base), "missing")
  assert_eq(errors_after(base), "missing")
  println("errors: 404 handled on both sides")
  assert_eq(stream_before(base), 8L)
  assert_eq(stream_after(base), 8L)
  println("stream: 8 bytes on both sides")
  let api = @mttp.client(base_url=base, retry=@mttp.RetryPolicy::none())
  defer api.close()
  let oversized = Bytes::make(65537, b'x')
  let reply = api.send(@mttp.post("/echo").body_bytes(oversized))
  assert_eq(reply.status, 413)
  assert_true(reply.body is Err(UnexpectedStatus(_, ..)))
  let accepted = api.send(
    @mttp.get("/missing").response(@mttp.as_string().any_status()),
  )
  assert_eq(accepted.status, 404)
  assert_eq(accepted.body, Ok(""))
  println("bounds: 65537-byte request refused with 413")
}

///|
async fn run_examples() -> Unit {
  for
    (name, serve) in [
      ("core server", shutdown_before),
      ("mttp server", shutdown_after),
    ] {
    println(name)
    @async.with_task_group(group => {
      serve("127.0.0.1:0", addr => {
        group.spawn_bg(() => {
          exercise("http://" + addr)
          group.return_immediately()
        })
      })
    })
  }
}

///|
async fn main {
  run_examples()
}
