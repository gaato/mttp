# Interoperability suite

`scripts/gates.sh interop websocket` runs the JS mttp Session on the
digest-pinned Node, Deno and Bun images against W5's native WebSocket echo,
then checks the fetch echo on Deno and Bun servers with the JS mttp client.
Text, binary, protocol selection, application Close code/reason and process shutdown are
checked end to end. `websocket/local` runs the same checks on installed
runtimes and prints their versions, explicitly without the container pins.
The Workers echo runs separately in `scripts/gates.sh workerd`.
The Bun client also sends a repeated Accept field to a native handshake that
requires both values. Deno/Bun server checks inspect application cookies and
host handshake fields on the wire, then await whenIdle() during shutdown while
the handler is sleeping outside recv.

WebSocket servers are checked with the digest-pinned Autobahn TestSuite in
fuzzingclient mode: `scripts/gates.sh interop server/autobahn`. The runner
starts `mttp_server websocket 127.0.0.1:39505`, writes its configuration and
reports under `_build/interop/autobahn`, and adapts every result to CASE lines.
Sections 1–7 and 10 run normally; section 9 raises the echo server's frame and
message limits to 128 MiB. Sections 12–13 are n/a until permessage-deflate.
Only exact documented INFORMATIONAL/NON-STRICT cases belong in known rows;
all other non-OK results fail.
Autobahn rows use `known:INFORMATIONAL/INFORMATIONAL` to require both exact
verdicts; FAILED, missing, duplicate or different verdicts fail the run on
either side. `moon run interop/run.mbtx -- --self-test` exercises the adapters
and these expectations without containers and also runs in static/full gates.

This uses the upstream
[Autobahn fuzzingclient interface](https://github.com/crossbario/autobahn-testsuite)
and the [RFC 6455 closing rules](https://www.rfc-editor.org/rfc/rfc6455.html).

Most of mttp's tests are self-consistent: the mttp client against the mttp
server, or against recorded bytes. Two implementations that share a
misunderstanding pass those. This suite runs mttp against widely used
third-party implementations instead:

- **The client** (`gaato/mttp`'s Client and backend,
  [mttp_client](mttp_client/main.mbt)) against nginx, Caddy and Apache
  httpd, over HTTP/1.1 and TLS, natively and as js under Node, Bun and Deno.
  It checks keep-alive reuse, a server closing an idle connection first,
  chunked responses, the content codings each server produces itself
  (gzip everywhere, zstd from Caddy, Brotli from Apache), RFC 9842's
  dictionary codings dcb and dcz from a Node server whose zlib codes with
  the dictionary the client stored ([dictionary.mjs](servers/dictionary.mjs)),
  HEAD, 204 and 304,
  301/302/307/308 redirects with credentials dropped across origins and no
  HTTPS-to-HTTP downgrade, `Expect: 100-continue` uploads and early refusals,
  16 MiB downloads and 8 MiB uploads, chunked uploads, trickled bodies and
  the client's deadlines, and a server that closes without answering.
- **The server** (`gaato/mttp`'s server,
  [mttp_server](mttp_server/main.mbt)) driven by curl, Go's net/http, Python
  httpx, and the fetch of Node, Bun and Deno ([clients](clients)), directly
  and behind nginx, Caddy and Apache as reverse proxies. It checks
  connection reuse (also through each proxy's upstream pool), chunked and
  large request bodies, `Expect: 100-continue`, streamed responses, HEAD and
  204, concurrent requests, RFC 9842 dcb and dcz from `dictionary_compress`
  (Node checks the header's hash and decodes them with node:zlib's
  dictionaries), HTTP/1.0, pipelining, and request smuggling
  shapes from raw sockets ([probes.py](clients/python/probes.py)): sent
  directly they must be refused as [CONTRACT.md](../CONTRACT.md) says, and
  through a proxy, whatever reaches the server must be unambiguous. Among
  them are bodies the server answers without reading (the 0.CL and CL.0
  shapes and early answers), which must never be read as a request.
- **The server** probed directly by
  [Http11Probe](https://github.com/MDA2AV/Http11Probe), a third-party suite
  of about 200 raw-socket tests of RFC 9110 and 9112 compliance, request
  smuggling, malformed input, header normalization, cookies, conditional
  requests and WebSocket upgrades. Each of its tests is a case
  `h11p-<test id>` (lowercased); a Warn, which the RFC allows, passes with
  `warn:` in its detail. The project publishes no image, so it is built
  from source at a pinned commit in the .NET SDK image
  ([build.sh](clients/http11probe/build.sh)), and
  [adapter.py](clients/http11probe/adapter.py) reads its report. The
  build is kept in `_build/interop/http11probe`, so later runs with the same
  pin need no network for it.
- **The typed endpoint layer** served by
  [openapi_server](openapi_server/main.mbt), with its own OpenAPI 3.1 document,
  driven directly by Schemathesis 4.33.4. Its four operations cover
  path/query/header/cookie inputs, a validated JSON body, 200/201/404/409 and
  framework problem responses, a required bearer scheme, a required response
  header and a finite SSE stream. Schemathesis runs the examples, coverage and
  fuzzing phases (not the stateful phase) with the seven stateless conformance
  checks, seed 20261116, one worker and at most 20 fuzz examples per operation.
  [adapter.mbtx](clients/schemathesis/adapter.mbtx) turns its JSON report into
  `st-*` cases.

[cases.tsv](cases.tsv) lists every case, where it runs and what it expects;
a case ending in `*` names every case starting with what precedes it, which
is how Http11Probe's tests are listed. The server configurations are in
[servers](servers). Every third-party
program runs from an image pinned by digest in [images.tsv](images.tsv), and
httpx is pinned with hashes in
[requirements.txt](clients/python/requirements.txt). Http11Probe is pinned
by commit in [run.mbtx](run.mbtx).

## Running it

From the repository root:

```sh
scripts/gates.sh interop
```

or `moon run interop/run.mbtx`, with an optional prefix to run part of it,
such as `moon run interop/run.mbtx -- client/native/apache` or `-- server/raw`.
It needs podman or docker (podman is preferred; `INTEROP_ENGINE` chooses),
openssl, a C compiler for moon's native target, and ports 39000, 39010,
39011, 39020, 39021, 39030 and 39031 free on 127.0.0.1 and 127.0.0.2, plus
39040, 39060 and 39061 (the Node dictionary server) on 127.0.0.1. A run
takes a few minutes once the images are pulled, about one of them
Http11Probe's (`-- server/http11probe`). CI runs it daily, in the
`interop` job of [canary.yml](../.github/workflows/canary.yml), not on pull
requests.

## Reading the results

Every case prints one line:

- `PASS client native/apache/https keepalive: ...`: the case behaved as
  expected. `client` runs read `<runtime>/<server>/<scheme>`, `server` runs
  `<client>/<target>`.
- `FAIL ...`: it did not. A failure caused by mttp is fixed in mttp, with a
  unit test that reproduces it. One caused by the third party becomes a
  KNOWN row.
- `KNOWN ...: ... [reason]`: the case shows a third-party behaviour that
  differs from what the case checks, and [cases.tsv](cases.tsv) says why it
  is not mttp's fault. A KNOWN case that starts to pass fails the run, so
  that the row is removed when a pin update fixes the quirk.

Cases that do not apply to a run are not printed; their `n/a` rows in
[cases.tsv](cases.tsv) say why. Most are js runs, where the host's fetch
owns connections, decoding and `Expect`.

## HTTP Garden

`mttp_server garden [address]` serves the HTTP Garden's base64 JSON echo on
`0.0.0.0:80` by default. It reads the complete body (up to 64 MiB), preserves
header names, duplicate order and Latin-1 value octets as handed to the handler,
and reports the request's protocol attribute. A failed body read lets the
engine return its error status. Garden mode retains no request log.
As in the codec, HTTP/1 minor versions above 1 are reported as `1.1`.

The `uri` is the handler URL's path and query, extracted without URL
normalization. The handler API has already converted origin-form to an absolute
URL and `OPTIONS *` to `/*` (`h1server/session.mbt`, `request_url`); the echo
cannot distinguish original absolute-form from origin-form, or `OPTIONS *`
from `OPTIONS /*`. Account for these adapter differences when interpreting
results. HEAD suppresses the response body as usual; Garden's mutation method
list excludes HEAD.

In a checkout of [http-garden](https://github.com/narfindustries/http-garden),
create `images/mttp/Dockerfile` with the following text. The commit selected by
`APP_VERSION` must contain Garden mode. The toolchain and core archive URLs use
that commit's `moonbit-version`; the binary archive is checked against MoonBit's
[published SHA-256](https://www.moonbitlang.com/download#verifying-binaries).
The pinned core archive currently has no published `.sha256` (403).

```dockerfile
FROM http-garden-soil:latest

RUN apt -y update \
 && apt -y install --no-install-recommends curl

ARG APP_REPO
ARG APP_BRANCH
ARG APP_VERSION
RUN git clone --branch "$APP_BRANCH" "$APP_REPO" /app/mttp \
 && cd /app/mttp \
 && git checkout --detach "$APP_VERSION"

ENV MOON_HOME=/opt/moon
ENV PATH="/opt/moon/bin:$PATH"
ENV MOON_CC=cc
RUN cd /app/mttp \
 && version=$(sed 's/+/%2B/g' moonbit-version) \
 && arch=$(uname -m) \
 && curl -fsSLo /tmp/moon.tar.gz "https://cli.moonbitlang.com/binaries/$version/moonbit-linux-$arch.tar.gz" \
 && curl -fsSLo /tmp/moon.sha256 "https://cli.moonbitlang.com/binaries/$version/moonbit-linux-$arch.tar.gz.sha256" \
 && echo "$(cut -d ' ' -f 1 /tmp/moon.sha256)  /tmp/moon.tar.gz" | sha256sum -c - \
 && mkdir -p "$MOON_HOME" \
 && tar xzf /tmp/moon.tar.gz -C "$MOON_HOME" \
 && chmod +x "$MOON_HOME"/bin/* "$MOON_HOME"/bin/internal/tcc \
 && curl -fsSLo /tmp/core.tar.gz "https://cli.moonbitlang.com/cores/core-$version.tar.gz" \
 && tar xzf /tmp/core.tar.gz -C "$MOON_HOME/lib" \
 && moon -C "$MOON_HOME/lib/core" bundle --warn-list -a --all \
 && rm /tmp/moon.tar.gz /tmp/moon.sha256 /tmp/core.tar.gz

WORKDIR /app/mttp
RUN moon update \
 && moon build --deny-warn --target native interop/mttp_server \
 && cp _build/native/debug/build/gaato/mttp-interop/mttp_server/mttp_server.exe /app/server

EXPOSE 80
CMD ["/app/server", "garden", "0.0.0.0:80"]
```

Add this service under `services` in Garden's `docker-compose.yml`, replacing
`<commit-containing-garden-mode>` with the reviewed commit:

```yaml
  mttp:
    build:
      context: ./images/mttp
      args:
        APP_REPO: https://github.com/gaato/mttp
        APP_BRANCH: main
        APP_VERSION: <commit-containing-garden-mode>
    x-props:
      role: origin
```

Use Garden's normal `./garden.sh start --build mttp gunicorn go_stdlib hyper
nginx node_stdlib` and `./garden.sh repl`. For example:

```text
payload 'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\n\r\n' | fanout mttp gunicorn go_stdlib hyper nginx node_stdlib | grid mttp gunicorn go_stdlib hyper nginx node_stdlib
```

Keep the input and full `fanout` output, not just the grid: Garden normalizes
some header differences, including Content-Length and Transfer-Encoding, and
its RFC validator is deliberately incomplete. Check each discrepancy against
[CONTRACT.md](../CONTRACT.md),
[h1server's guarantees](../mttp_core/src/h1server/README.mbt.md) and
[documented conformance differences](../conformance/data/h1_differences.txt).

WebSocket clients run against the digest-pinned Autobahn TestSuite 25.10.1
in fuzzingserver mode (`interop/servers/autobahn-client.json`):

```sh
INTEROP_ENGINE=docker moon run interop/run.mbtx -- client/native/autobahn
```

The native `ws_client` asks for every case, echoes messages, and requests the
JSON report; `clients/autobahn/adapter.mbtx` converts both behavior and close verdicts
to CASE lines. Raw reports remain in `_build/interop/autobahn-client/reports`.
The [upstream configuration](https://github.com/crossbario/autobahn-testsuite)
selects sections 1–7, 9 and 10; 12–13 are excluded until permessage-deflate.
Section 9 uses explicit 64 MiB frame/message limits and a raised empty-frame
work limit. The shared adapter requires strict OK for case 2.10: the session
answers each Ping while its Pong writer is free. Only 7.1.6, 7.13.1 and
7.13.2 allow the exact INFORMATIONAL/INFORMATIONAL verdict pair.
