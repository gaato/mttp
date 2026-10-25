///|
test "definition checker reports malformed methods captures body combinations and headers" {
  let empty : @endpoint.Out[Unit] = @endpoint.one_of([])
  let invalid = [
    @endpoint.endpoint.get("/").post("/").doc(),
    @endpoint.endpoint.get("/{bad").doc(),
    @endpoint.endpoint.get("/{}").doc(),
    @endpoint.endpoint.get("/{x{y}}").doc(),
    @endpoint.endpoint
    .get("/{tail...}/later")
    .input(@endpoint.paths("tail"))
    .doc(),
    @endpoint.endpoint.get("/{...}").doc(),
    @endpoint.endpoint
    .get("/{tail...}")
    .input(@endpoint.path("tail", @schema.string))
    .doc(),
    @endpoint.endpoint
    .get("/")
    .input(@endpoint.path("extra", @schema.string))
    .doc(),
    @endpoint.endpoint
    .get("/{id}")
    .input(@endpoint.path("id", @schema.string).optional())
    .doc(),
    @endpoint.endpoint
    .get("/{id}")
    .input(
      @endpoint.pair(
        @endpoint.path("id", @schema.string),
        @endpoint.path("id", @schema.string),
      ),
    )
    .doc(),
    @endpoint.endpoint.get("/").input(@endpoint.body(@schema.text_body)).doc(),
    @endpoint.endpoint
    .post("/")
    .input(
      @endpoint.pair(
        @endpoint.body(@schema.text_body),
        @endpoint.body(@schema.text_body),
      ),
    )
    .doc(),
    @endpoint.endpoint
    .post("/")
    .security(@endpoint.pair(@endpoint.raw_body(), @endpoint.raw_body()))
    .doc(),
    @endpoint.endpoint
    .post("/")
    .security(@endpoint.body(@schema.text_body))
    .doc(),
    @endpoint.endpoint
    .post("/")
    .security(@endpoint.raw_body())
    .input(@endpoint.stream_body())
    .doc(),
    @endpoint.endpoint.post("/").output(empty).doc(),
    @endpoint.endpoint.get("/").output(@endpoint.text_out(status=99)).doc(),
    @endpoint.endpoint.get("/").output(@endpoint.text_out(status=204)).doc(),
    @endpoint.endpoint
    .get("/")
    .output(@endpoint.text_out().and_header("content-type", @schema.string))
    .doc(),
    @endpoint.endpoint
    .get("/")
    .output(@endpoint.text_out().and_header("bad name", @schema.string))
    .doc(),
    @endpoint.endpoint
    .get("/")
    .output(
      @endpoint.text_out()
      .and_header("x", @schema.string)
      .and_header("X", @schema.string),
    )
    .doc(),
  ]
  for doc in invalid {
    assert_true(!doc.problems().is_empty())
  }
  let variants = [@endpoint.empty_variant(400), @endpoint.empty_variant(400)]
  let errors = @endpoint.Errors::new(_ => None, variants)
  let doc = @endpoint.endpoint.get("/").errors(errors).doc()
  assert_true(@endpoint.check_definitions([doc]).iter().any(p => !p.fatal))
}

///|
test "builders preserve metadata and explicit limiter buckets independently of operation IDs" {
  assert_eq(
    @endpoint.endpoint.path("/base/").get("/item").doc().template,
    "/base/item",
  )
  for
    doc in [
      @endpoint.endpoint.put("/").doc(),
      @endpoint.endpoint.patch("/").doc(),
      @endpoint.endpoint.head("/").doc(),
      @endpoint.endpoint.options("/").doc(),
      @endpoint.endpoint.delete("/").doc(),
    ] {
    assert_eq(doc.problems(), [])
  }
  let ep = @endpoint.endpoint
    .get("/")
    .operation_id("operation")
    .rate_limit_bucket(_ => "bucket")
  let request = ep.request((), ()).raw()
  assert_eq(request.attributes.get(@client.rate_limit_bucket), Some("bucket"))
  assert_eq(request.attributes.get(@client.operation_id), Some("operation"))
  assert_eq(
    @endpoint.endpoint.get("/").operation_id("operation").request((), ()).raw().attributes.get(
      @client.rate_limit_bucket,
    ),
    None,
  )
  let info = @endpoint.Info::new(
    operation_id="id",
    summary="summary",
    description="description",
    tags=["tag"],
    deprecated=true,
  )
  assert_true(info.deprecated)
  let variant = @endpoint.VariantDoc::new(
    201,
    media_type="text/plain",
    schema=@schema.string.schema(),
    headers=["x"],
    description="created",
  )
  assert_eq(variant.status, 201)
  assert_eq(
    @endpoint.bytes_out().docs()[0].media_type,
    Some("application/octet-stream"),
  )
}
