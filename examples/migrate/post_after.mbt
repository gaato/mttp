///|
pub async fn post_after(base : String) -> String {
  let api = @mttp.client(base_url=base)
  defer api.close()
  api.send(
    @mttp.post("/echo")
    .body_json({ "name": "Ada" })
    .header("X-Request-Id", "demo"),
  ).body.unwrap()
}
