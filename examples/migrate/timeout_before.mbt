///|
pub async fn timeout_before(base : String) -> String {
  @async.with_timeout(1000, () => {
    let (_, body) = @http.get(base + "/hello")
    body.text()
  })
}
