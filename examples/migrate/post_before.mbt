///|
pub async fn post_before(base : String) -> String {
  let (_, body) = @http.post_json(base + "/echo", { "name": "Ada" }, headers={
    "Content-Type": "application/json",
    "X-Request-Id": "demo",
  })
  body.text()
}
