///|
async test "typed endpoint runs without the Workers host or sockets" {
  let app = @worker.application()
  defer app.close()
  let client = @mttp.client(backend=app)
  defer client.close()
  assert_eq(
    @worker.hello.call(client, (), "Moon").unwrap().unwrap(),
    "Hello, Moon",
  )
  assert_eq(app.dispatch(@mttp.Request::get("/missing")).status, 404)
}
