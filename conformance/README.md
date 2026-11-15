# HTTP conformance corpora

This unpublished module checks `gaato/mttp_core` through public
APIs on all four targets. It retains the HTTP-only suites from mbt-sdk
commit `43f92f0`:

- URL parsing against 245 applicable WHATWG URL vectors, including all 19
  previously excluded IPv6/IPv4-tail rows. IPv6 serialization uses RFC 5952
  hex throughout. The remaining RFC 3986 exclusions have pinned skip counts.
- Form/query parsing and CookieJar behavior against WPT and http-state data.
- SSE results, truncation, end-of-stream behavior and overflow under every
  short-input split, hostile UTF-8/CRLF splits and seeded mutations.
- The HTTP/1 codec (`gaato/mttp_core/h1`) against 212 of llhttp's 255
  request and response tests and 165 rows of web-platform-tests' HTTP/1
  response parsing tables, each read whole, split in two at every offset,
  one byte at a time and cut after every CR.

The SSE size-limit classification is `TransportError(kind=TooLarge)`, matching
the new transport error vocabulary; event results and mutation counts remain
unchanged. The tests use no runtime and no wall clock. Cookie time comes from
the explicit FakeClock. JSON-RPC corpora remain in mbt-sdk.

See [NOTICE](NOTICE) for upstream revisions and licenses.
[scripts/gen_vectors.mbtx](../scripts/gen_vectors.mbtx) writes every file
marked GENERATED from those revisions; its header says how. The regular gates
include this module and enforce equal per-package counts on native, wasm,
wasm-gc and JS.

The URL suite intentionally excludes backslash handling, special schemes
without `//`, encoded dot segments, apostrophe encoding in queries, empty
hosts, IDNA/percent-encoded hosts, hosts outside RFC reg-name, noncanonical
IPv4 numeric hosts, and empty userinfo/password normalization. It compares
empty HTTP paths as `/`, as RFC 9110 permits. These are the inherited RFC
3986 conventions, not newly accepted parser failures.

The cookie parser corpus keeps three inherited exclusions: cases disabled
upstream, nameless cookies, and an empty last Domain attribute. The latter
two differ between RFC 6265 and the implemented RFC 6265bis-22. Cookie date,
form and SSE vectors have no exclusions.

## HTTP/1 vectors

[data/](data) keeps the upstream cases verbatim: each llhttp test's heading,
metadata, input block and expected callback log (`llhttp.json`), and the
`.asis` responses, handler templates and expectation tables of WPT's
`fetch/h1-parsing` and `fetch/content-length` (`wpt-fetch.json`). The
generator's extract step writes them from a checkout; its generate step turns
them into `src/http1/*_vectors_test.mbt` offline, and the static gates rerun it
with `--check`.

Each case becomes a reading: per message its start line, fields, body,
trailers and whether it completed, then how the input ended (refused with a
`ParseKind`, handed off after CONNECT or an upgrade, closed after
`Connection: close`, or used up). The generator derives the expected reading
from llhttp's log or WPT's table, rewriting inputs as llhttp's test runner
does. Three conversion rules apply:

- An HTTP/1.1 request without `Host` gets `Host: h` after its request line,
  because RFC 9112 section 3.2 makes a server refuse it and llhttp does not
  check; the case is about something else.
- llhttp's field-value spans keep trailing whitespace, which RFC 9112 section
  5 excludes from the value, as mttp does.
- WPT's status-code handler ends lines with bare LF and leaves the head
  unterminated; the import uses CRLF and ends the head, so the rows test the
  status line. Bare LF and lone CR have rows of their own.

A refusal maps to `Malformed`, or `Smuggling` for llhttp's conflicting
Content-Length and Transfer-Encoding errors, unless
[data/h1_differences.txt](data/h1_differences.txt) names another kind.
That file also lists, with reasons citing RFC 9110/9112, CONTRACT.md and the
codec's README, every case where mttp's documented strictness reads the input
otherwise: llhttp's lenient modes, an empty line before a status line, a
target with a fragment, a repeated or invalid Content-Length that fetch
tolerates, and so on (57 llhttp and 31 WPT cases). Those cases run too, and
fail if mttp starts reading them as the source does. Cases about llhttp's own
callbacks (pause, skip-body, `llhttp_finish`), RTSP, ICE and the HTTP/2
preface are skipped and counted, as are two WPT responses that wptserve
writes itself and one about a body cut short by the close, which mttp's
engines report. WPT's MIME-type table is not imported: mttp has no MIME-type
parser (`media_type_token` only cuts parameters). WPT's `cookies/` tests run
in a browser; the http-state corpus above covers the parser.

From the workspace root, run the suites with:

```sh
moon test conformance/src/cookie conformance/src/http1 conformance/src/sse conformance/src/url --target wasm-gc
scripts/gates.sh full
```
