///|
test "transport and URL errors interpolate as messages" {
  let error = @mttp.TransportError(
    kind=Timeout(ms=200),
    phase=Head,
    detail="the request head exceeded 200 ms",
  )
  assert_eq("\{error}", error.message())
  assert_eq(
    @mttp.UrlError::Invalid("no scheme").to_string(),
    "invalid URL: no scheme",
  )
}
