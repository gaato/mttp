///|
test "client errors and failures interpolate as messages" {
  let head : @mttp.ResponseHead = {
    status: 404,
    headers: @mttp.Headers::empty(),
  }
  assert_eq(
    @client.InvalidRequest(message="no URL").to_string(),
    "invalid request: no URL",
  )
  assert_eq(
    "\{@client.UnexpectedStatus(head, body=b"")}",
    "unexpected status 404",
  )
  assert_eq(
    "\{@client.Deserialization({ ..head, status: 200 }, message="bad JSON", body=b"")}",
    "the 200 response did not decode: bad JSON",
  )
}
