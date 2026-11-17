///|
pub async fn reuse_before(base : String) -> String {
  let api = @http.Client(headers={ "X-Request-Id": "demo" })
  defer api.close()
  let (_, first) = api.get(base + "/hello")
  let (_, second) = api.get(base + "/hello")
  first.text() + ", " + second.text()
}
