# gaato/mttp_core/urlpattern

URL patterns as the [WHATWG URL Pattern Standard](https://urlpattern.spec.whatwg.org/)
defines them, without regular expressions, for the `match` of a
[RFC 9842](https://www.rfc-editor.org/rfc/rfc9842) compression dictionary.

`UrlPattern::parse` reads a pattern written as one string, relative to a
base URL when given, as `new URLPattern(input, base)` does;
`UrlPattern::new` takes the components separately, as
`new URLPattern({ pathname: ... })` does. `matches` and `matches_init`, the standard's `test`, say whether
a URL matches; a `Url`, which follows RFC 3986, is first read as WHATWG's
URL parser keeps it (IPv4 numbers, dot segments, percent-encoding). Where
RFC 3986 parsing has already changed the string, the answer is for the
`Url` as parsed: `Url::parse` resolves `..` but keeps `%2e%2e`, and
percent-encodes characters, such as `^`, that WHATWG keeps in an opaque
path. Named groups (`:name`), wildcards (`*`), groups in braces
with `?`, `*` and `+`, escapes and every component are supported; the
pattern strings are canonicalized as the standard does, and `components`
gives them back.

Matching runs an automaton over the input once, in time proportional to
the input's length times the pattern's, so no pattern can make it
backtrack. A regular expression group, such as `:id(\\d+)` or `(foo|bar)`, is
refused with `RegexpGroup`: RFC 9842 does not allow one in `match`, and
this package has no regular expression engine. A group whose expression is
the standard's own for a segment or a wildcard is not one, as the standard
says.

Left out, and why:

- regular expression groups, as above;
- the `ignoreCase` option, which RFC 9842 does not use;
- hostnames past ASCII, which need IDNA tables; they raise `Unsupported`,
  from `matches_init` too, rather than answer wrongly;
- `exec` and its groups: only whether a URL matches is computed.

Group names are made of Unicode 18.0.0's ID_Start and ID_Continue, as
ECMAScript identifiers are. Arguments are taken as USVStrings, as WebIDL
passes them to the standard: a lone surrogate becomes U+FFFD.

```mbt check
///|
test "a dictionary's match, relative to the dictionary's URL" {
  let base = @mttp_core.Url::parse("https://example.com/app/v1/main.js")
  let p = @urlpattern.UrlPattern::parse("/app/*/main.js", base~)
  assert_true(
    p.matches(@mttp_core.Url::parse("https://example.com/app/v2/main.js?x=1")),
  )
  assert_false(
    p.matches(@mttp_core.Url::parse("https://example.com/other/main.js")),
  )
  assert_false(
    p.matches(@mttp_core.Url::parse("https://example.org/app/v2/main.js")),
  )
  let refused = try {
    @urlpattern.UrlPattern::parse("/app/:v(\\d+)/main.js", base~) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_eq(refused, Some(@urlpattern.RegexpGroup))
}
```
