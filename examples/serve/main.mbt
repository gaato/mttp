///|
async fn main {
  let args = @env.args()
  guard args.length() == 2 else {
    println("usage: serve <address>")
    @env.exit(2)
  }
  @server.serve(
    _ => @http.Response::new(200, body=Bytes(b"hello\n")),
    addr=args[1],
    on_listen=addr => println("listening on \{addr}"),
  )
}
