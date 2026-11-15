// web-platform-tests' HTTP/1 response parsing tables (fetch/h1-parsing and
// fetch/content-length, see NOTICE), read by mttp's codec as a client.
// A network error is a refusal; a response fetch reads must read the same.

///|
test "web-platform-tests responses read as fetch expects, at every split" {
  let (cases, differences) = check_tables(wpt_cases, wpt_differences)
  inspect(
    "\{cases} cases, \{differences} differences",
    content=(
      #|134 cases, 31 differences
    ),
  )
  debug_inspect(
    skipped(wpt_skipped),
    content=(
      #|[
      #|  "2 responses that wptserve writes, not the test data",
      #|  "1 a body shorter than its Content-Length, an end-of-input error mttp's engines report",
      #|]
    ),
  )
}
