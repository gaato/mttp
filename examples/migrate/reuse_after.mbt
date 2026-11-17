///|
pub async fn reuse_after(base : String) -> String {
  let api = @mttp.client(
    base_url=base,
    headers=@mttp.Headers::of([("X-Request-Id", "demo")]),
  )
  defer api.close()
  let first = api.send(@mttp.get("/hello")).body.unwrap()
  let second = api.send(@mttp.get("/hello")).body.unwrap()
  first + ", " + second
}
