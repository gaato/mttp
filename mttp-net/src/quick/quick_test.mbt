///|
async test "quick creates and recreates its default client without eager IO" {
  @quick.close()
  @quick.close()
  for _ in 0..<2 {
    for _ in 0..<2 {
      try {
        let _ = @quick.send(
          @client.quick_request(@model.Request::get("ftp://example.test/")),
        )
        fail("unsupported scheme accepted")
      } catch {
        @model.TransportError(..) => ()
        error => raise error
      }
    }
    @quick.close()
  }
}
