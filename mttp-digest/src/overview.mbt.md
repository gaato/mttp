# Origin-scoped Digest backend

```mbt check
///|
test {
  let inner = @client.from_fn((_, _) => @model.Response::new(200))
  let backend = @mttp_digest.DigestScheme::new(
    inner,
    "user",
    "password",
    origin="https://api.example.test",
    random=() => 0.5, // deterministic test source; inject secure randomness in production
  )
  @testing.run_sync(() => {
    let response = backend.send(
      @model.Request::get("https://api.example.test/"),
      @client.RequestOptions::default(),
    )
    assert_eq(response.status, 200)
    response.close()
  })
  backend.close()
}
```
