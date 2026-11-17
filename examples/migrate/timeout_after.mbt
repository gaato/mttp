///|
pub async fn timeout_after(base : String) -> String {
  let api = @mttp.client(base_url=base, timeout_ms=1000, total_ms=3000)
  defer api.close()
  api.send(@mttp.get("/hello").timeout_ms(500)).body.unwrap()
}
