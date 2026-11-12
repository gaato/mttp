// When the backend replaces its moonfetch client, and when it closes the old
// one. Closing a client does not cut a response whose bytes already arrived,
// so the black-box tests cannot tell an early close from a late one; these
// read the generations' state instead.

///|
test "a client is replaced after exchanges_per_client sends and closed with its last response" {
  let backend = MoonfetchBackend::new(http3=false)
  let first = backend.generation()
  assert_true(physical_equal(backend.generation(), first))
  // One response still open when the limit is reached.
  first.sends = exchanges_per_client
  first.open = 1
  let second = backend.generation()
  assert_false(physical_equal(second, first))
  assert_true(first.retired)
  assert_false(first.closed)
  assert_eq(backend.retired.length(), 1)
  first.release()
  assert_true(first.closed)
  // No response open: the replaced client closes at once, and the closed one
  // above leaves the list of those still owed.
  second.sends = exchanges_per_client
  let third = backend.generation()
  assert_true(second.closed)
  assert_eq(backend.retired.length(), 0)
  assert_false(third.closed)
}

///|
test "closing the backend closes the current client and every replaced one" {
  let backend = MoonfetchBackend::new(http3=false)
  let first = backend.generation()
  first.sends = exchanges_per_client
  first.open = 1
  let second = backend.generation()
  @mttp.Backend::close(backend)
  assert_true(first.closed)
  assert_true(second.closed)
  // An exchange that ends after the backend closed closes its client
  // again, for a connection it may have opened after the close.
  first.release()
  assert_true(first.closed)
  assert_eq(first.open, 0)
}

///|
test "with a proxy, the client is built without HTTP/3" {
  let proxy = @moonfetch.Proxy::parse("http://proxy.example:3128")
  assert_false(MoonfetchBackend::new(http3=true, proxy~).http3)
  assert_true(MoonfetchBackend::new(http3=true).http3)
}
