///|
/// The router as an in-process Backend passes trailer fields through both
/// ways: a request body's reach the handler's reader once it read to the
/// end, and a response body's reach the caller.
test "trailers pass through the router as a Backend" {
  let seen : Ref[String?] = Ref(None)
  let ep = @endpoint.endpoint
    .post("/t")
    .input(@endpoint.stream_body())
    .output(@endpoint.stream_body_out())
    .serve_public(reader => {
      let bytes = @mttp_core.Body::Stream(@mttp_core.StreamBody::new(reader)).read_all(
        max=1024,
      ) catch {
        _ => b""
      }
      seen.val = reader.trailers().get("x-checksum")
      Ok(
        (
          None,
          @mttp_core.Body::with_trailers(
            bytes,
            trailers=@mttp_core.Headers::of([("grpc-status", "0")]),
          ),
        ),
      )
    })
  let router = @router.Router::new([ep])
  @driver.run_sync(() => {
    let request = {
      ..@mttp_core.Request::post("/t").header(
        "content-type", "application/octet-stream",
      ),
      body: @mttp_core.Body::with_trailers(
        b"abc",
        trailers=@mttp_core.Headers::of([("x-checksum", "9")]),
      ),
    }
    let response = router.send(request, @mttp_core.SendOptions::default())
    assert_eq(response.body.read_all(max=1024), b"abc")
    assert_eq(response.body.trailers().get("grpc-status"), Some("0"))
  })
  assert_eq(seen.val, Some("9"))
}
