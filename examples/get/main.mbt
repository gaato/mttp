///|
fn main {
  let args = @env.args()
  guard args.length() == 2 else {
    println("usage: get <url>")
    @env.exit(2)
  }
  @mttp.run(async fn() {
    let client = @mttp.client()
    defer client.close()
    let reply = client.send(@mttp.get(args[1]))
    println("status: \{reply.status}")
    match reply.body {
      Ok(text) => println(text)
      Err(_) => println("no text body: the request did not succeed")
    }
  })
}
