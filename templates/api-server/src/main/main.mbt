///|
fn main {
  guard @env.get_env_var("API_TOKEN") is Some(token) && !token.is_empty() else {
    abort("Set API_TOKEN to a non-empty bearer token")
  }
  let address = @env.get_env_var("LISTEN_ADDR").unwrap_or("127.0.0.1:8080")
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM])
  @mttp.run(async fn() {
    let app = @api.application(token)
    defer app.close()
    @server.serve(app.handler(), addr=address)
  })
}
