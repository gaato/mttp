// The canonicalization callbacks and helpers one at a time, against what
// WHATWG's URL parser gives for the same input.

///|
fn canon(f : (String) -> String raise PatternError, v : String) -> String? {
  Some(f(v)) catch {
    _ => Option::None
  }
}

///|
test "hostnames: IPv4 numbers, percent-decoding, IPv6 and refusals" {
  let host = (v : String) => canon(canonicalize_hostname, v)
  assert_eq(host("0x7F.0.0.1"), Some("127.0.0.1"))
  assert_eq(host("0177.1"), Some("127.0.0.1"))
  assert_eq(host("127.1."), Some("127.0.0.1"))
  assert_eq(host("4294967295"), Some("255.255.255.255"))
  assert_eq(host("4294967296"), Option::None)
  assert_eq(host("1.2.3.256"), Option::None)
  assert_eq(host("1.2.3.4.5"), Option::None)
  assert_eq(host("99999999999999999999999"), Option::None)
  assert_eq(host("exa%6Dple.com"), Some("example.com"))
  assert_eq(host("ex%zzample"), Option::None)
  assert_eq(host("%ff.com"), Option::None)
  assert_eq(host("[::1]"), Some("[::1]"))
  assert_eq(host("[::1"), Option::None)
  assert_eq(host("[nothex]"), Option::None)
  assert_eq(host("/path"), Option::None)
  assert_eq(host("a b"), Option::None)
  assert_eq(host("example.com/path"), Some("example.com"))
  assert_eq(canon(opaque_host, "a b"), Option::None)
  assert_eq(canon(opaque_host, "Ab\u{1}"), Some("Ab%01"))
}

///|
test "ports: digits up to 65535, the default port dropped" {
  let port = (v : String, p : String?) => canon(x => canonicalize_port(x, p), v)
  assert_eq(port("0", Option::None), Some("0"))
  assert_eq(port("0080", Some("http")), Some(""))
  assert_eq(port("21", Some("ftp")), Some(""))
  assert_eq(port("8080abc", Option::None), Some("8080"))
  assert_eq(port("65536", Option::None), Option::None)
  assert_eq(port("1000000", Option::None), Option::None)
  assert_eq(port("x", Option::None), Option::None)
}

///|
test "paths: dot segments, an empty last segment, and the encode sets" {
  assert_eq(canonicalize_pathname("/a/./b/../c"), "/a/c")
  assert_eq(canonicalize_pathname("/a/.."), "/")
  assert_eq(canonicalize_pathname("/a/."), "/a/")
  assert_eq(canonicalize_pathname("x y"), "x%20y")
  assert_eq(canonical_query("a'b c", false), "a'b%20c")
  assert_eq(canonical_query("a'b", true), "a%27b")
  assert_eq(canonicalize_hash("a b"), "a%20b")
}

///|
test "protocols and the authority after them" {
  let proto = (v : String) => canon(canonicalize_protocol, v)
  assert_eq(proto("https:[::1]"), Some("https"))
  assert_eq(proto("https:[::1]x"), Option::None)
  assert_eq(proto("https:a:x"), Option::None)
  assert_eq(proto("1http"), Option::None)
  assert_eq(proto("ht tp"), Option::None)
}

///|
test "helpers: hex digits, IPv4 numbers and hosts as WHATWG writes them" {
  assert_eq(hex_value('F'), Some(15))
  assert_eq(hex_value('g'), Option::None)
  assert_eq(ipv4_number("010"), Some(8L))
  assert_eq(ipv4_number("0x"), Some(0L))
  assert_eq(ipv4_number("08"), Option::None)
  assert_true(ends_in_number("a.0x10"))
  assert_false(ends_in_number("a.0xg"))
  assert_eq(url_host(Option::None), "")
  assert_eq(url_host(Some("::1")), "[::1]")
  assert_true(is_name_char('$', true))
  assert_true(is_name_char('é', true))
  assert_false(is_name_char('1', true))
  assert_true(is_name_char('\u{200C}', false))
}

///|
test "the tokenizer: lenient errors become invalid-char tokens" {
  let kinds = try! tokenize("(a\u{e9})(?x)(a(b)(a".to_array(), true).map(t => {
    t.kind
  })
  // "(" before a non-ASCII character, "(?", "(" with a group not opened
  // by "(?", and "(" that never closes are invalid; "(b)" is a regexp.
  assert_eq(kinds.length(), 14)
  for i in [0, 4, 8, 11] {
    assert_true(kinds[i] is InvalidChar)
  }
  assert_true(kinds[10] is Regexp)
  assert_true(kinds[5] is OtherModifier)
  let strict_fails = (s : String) => {
    try {
      tokenize(s.to_array(), false) |> ignore
      false
    } catch {
      _ => true
    }
  }
  assert_true(strict_fails("(a\\"))
  assert_true(strict_fails("(a\\\u{e9})"))
  assert_true(strict_fails("()"))
}

///|
test "pattern strings write a regular expression part" {
  let parts = try! parse_pattern("/:id(\\d+)", pathname_options, s => s)
  assert_eq(pattern_string(parts, pathname_options), "/:id(\\d+)")
}

///|
test "the constructor parser reads past its last token as the end" {
  let chars = "a".to_array()
  let p : CtorParser = {
    input: chars,
    tokens: try! tokenize(chars, true),
    result: PatternInit::new(),
    component_start: 0,
    token_index: 0,
    token_increment: 1,
    group_depth: 0,
    ipv6_depth: 0,
    protocol_is_special: false,
    state: Init,
  }
  assert_true(p.safe_token(99).kind is End)
  p.set_component(Init, "ignored")
  assert_eq(p.result, PatternInit::new())
}
