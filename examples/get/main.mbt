///|
fn main {
  @mttp.run(async fn() {
    let client = @mttp.client()
    defer client.close()
    let reply = client.send(@mttp.get("https://example.com/"))
    match reply.body {
      Ok(text) => println("\{reply.status}: \{text.length()} characters")
      Err(failure) => println("\{reply.status}: \{failure}")
    }
  })
}
