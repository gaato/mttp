// llhttp's request and response tests (see NOTICE), read by mttp's codec.
// scripts/gen_vectors.mbtx turns each test's expected callback log into the
// reading mttp gives for it; the cases where mttp's documented strictness
// answers otherwise are in `llhttp_differences` with their reasons, and the
// cases about llhttp's own callbacks and protocols are counted as skipped.

///|
test "llhttp cases read as llhttp expects, at every split" {
  let (cases, differences) = check_tables(llhttp_cases, llhttp_differences)
  inspect(
    "\{cases} cases, \{differences} differences",
    content=(
      #|154 cases, 58 differences
    ),
  )
  debug_inspect(
    skipped(llhttp_skipped),
    content=(
      #|[
      #|  "1 the HTTP/2 connection preface",
      #|  "12 RTSP, ICE and Icecast SOURCE, which are not HTTP",
      #|  "24 pause callbacks, which mttp's codec has no equivalent for",
      #|  "4 llhttp_finish, the end-of-input call; mttp's engines own end of input",
      #|  "2 a callback that skips the body, which mttp's codec has no equivalent for",
      #|]
    ),
  )
}
