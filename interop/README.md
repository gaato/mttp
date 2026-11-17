# Interoperability suite

`scripts/gates.sh interop client/native/socks5h` runs the native client
through the digest-pinned `serjs/go-socks5-proxy` image against HTTP and
verified HTTPS on nginx. It checks RFC 1929 authentication, wrong-password
refusal and tunnel reuse. The proxy admits only the original FQDN
`localhost`, ensuring the client uses ATYP domain-name remote DNS. No
SOCKS server implementation is added to mttp. Ports 39010, 39011 and 39060
must be free. The image and its source revision are pinned in images.tsv;
the standard interop run includes these two client-only cases.

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
message limits to 128 MiB. Sections 12–13 run with opt-in permessage-deflate
in both directions (`client/native/autobahn` checks the mttp client). Only
window 15 can be promised by our encoder; smaller peer encoding windows are
accepted by our 32 KiB decoder. RFC 7692 §7.1.2.1 requires the server to
decline offers constraining its encoder below 15; §7.1.2.2 responses that
constrain the client encoder below 15 fail the client handshake.
Set `INTEROP_WS_COMPRESSION_ONLY=1` for a focused run of sections 12 and 13
in either direction; it retains exact verdict checking and leaves the default
full suite unchanged. The Autobahn process ceiling is one hour per batch
because the compression matrix can outlast the ordinary ten-minute ceiling.
Both Autobahn directions use native release builds; the client permits
600 seconds per case, beyond the suite's longest 480-second case deadline.

The native client suite restarts its fuzzing server between batches:
`basic` (sections 1–11, 301 cases), then one batch per subsection of the
compression sections 12 and 13 (`12.1`, `12.2`, …, `13.7`). A whole
section 12 on one server was killed for memory on a 16 GB GitHub runner.
The pinned suite currently has no cases in sections 8 or 11. A short initial
`inventory` server only answers `/getCaseCount` and `/getCaseInfo`; it runs no
test cases. Its complete case inventory is partitioned without exclusions,
so new non-compression cases also go into `basic`. Compression-only mode
selects the 216 compression cases from that same inventory.

Each batch owns `_build/interop/autobahn-client/<batch>/reports/index.json`
and its own `client.log`, `server.log`, and `state.txt`. The previous layout
is removed before discovery. `expected.txt` lists every selected case ID.
The adapter reads every batch report with `--client-reports expected.txt
index.json...` and validates the complete union before emitting CASE lines:
missing files, empty/malformed reports, missing cases even inside nonempty
wildcards, duplicate cases, and unexpected cases all fail. IDs and verdicts
remain unchanged; numeric `/runCase` indices restart in each batch.

Each fuzzing server runs without a per-container memory cap by default:
canary run 44040380746 showed a 5 GiB cap killing section 12's server about
20 s in on a GitHub runner, which has 16 GB. `INTEROP_AUTOBAHN_MEMORY` sets a
cap for experiments (for example `5g`, or `3g` for a pressure test).
Restarting the server releases PyPy's retained case data and compression
state. Canary run 44022015993 confirmed OOMKilled/137 during old full-suite
case 367 (12.4.12), followed by connection refused and no reports. In that
old ordering section 12 started at 302 and section 13 at 392. Local unsplit
3 GiB runs also OOM-killed the server at varying positions; increasing the
report wait did not address that failure.

Cleanup validation on 2026-11-17 used Docker without per-container memory
limits (`INTEROP_AUTOBAHN_MEMORY=0`): all 517 cases produced reports, with
460 passed, 57 exact known verdicts and 0 failed. The complete command took
314.86 seconds after acquiring the gates lock. With container tracing enabled,
the observed peak was one running container, and every inventory/batch
boundary showed zero. Separate lifecycle tests started all four HTTP servers
together (peak four), then verified all four were removed; normal, failed,
CLI-cancelled and batch-cancelled paths also ended with zero containers.

Container ownership is independent of the `docker run`/`podman run` client
process. Every invocation has a unique name. Group cleanup runs after CLI
children have terminated and executes `rm -f NAME` protected from cancellation,
then queries the daemon to verify the name is absent. It retries transient
removal failures and aborts if absence cannot be verified, before another
batch can start. The `state.txt` snapshot is explicitly **before removal**;
`Running=true` there does not establish that the container survived cleanup.
Foreground tools (including Http11Probe builds/runs and Autobahn's server
direction), HTTP servers, SOCKS proxies and WebSocket hosts use the same
checked cleanup. `INTEROP_CONTAINER_TRACE=1` prints `docker ps`/`podman ps`
tables and the observed peak count at lifecycle boundaries.
`moon run interop/run.mbtx -- --self-test-containers` exercises real normal,
failed, cancelled and unverifiable-daemon cleanup, including cancellation of
a fuzzing-server batch. Run it under the same gates lock as other interop runs.

Client-run failures print outcome counts and first/last full errors per kind,
the container state (including `OOMKilled`), and each affected fuzzing server's
last 80 log lines (at most 16 KiB). Newlines in full error representations
are escaped. Logs survive client timeouts, and a stopped server ends the
report wait immediately. These observations include intentional frame and
handshake rejections; the reports still decide protocol verdicts.
Only exact documented INFORMATIONAL/NON-STRICT cases belong in known rows;
all other non-OK results fail, except the fixed-window cases below.
Autobahn rows use `known:INFORMATIONAL/INFORMATIONAL` to require both exact
verdicts; FAILED, missing, duplicate or different verdicts fail the run on
either side. `moon run interop/run.mbtx -- --self-test` exercises the adapters
and these expectations without containers and also runs in static/full gates.

The 2026-11-16 focused sections 12/13 run uses the Autobahn image digest in
images.tsv, MoonBit 0.10.20+65efd5b93 and native release builds:

| Direction | Section 12 | Section 13 | Exact known verdict |
|---|---|---|---|
| Autobahn client → mttp server | 90 OK/OK | 90 OK/OK, 36 known | 13.3.* and 13.5.*: UNIMPLEMENTED/OK |
| mttp client → Autobahn server | 90 OK/OK | 72 OK/OK, 54 known | 13.3.*, 13.5.* and 13.7.*: FAILED/FAILED |

Every known server case requests `server_max_window_bits=9`; every known
client case responds with `client_max_window_bits=9`. All 90 raw handshake
records were checked for those constraints. A fixed-window-15 encoder must
decline the server offer or fail the unsupported client response under
[RFC 7692 sections 7 and 7.1.2](https://www.rfc-editor.org/rfc/rfc7692.html#section-7.1.2).
The client 13.7.* descriptions list fallback offers, but the actual server
response still selects client window 9. These raw failures remain recorded
as FAILED/FAILED; they are not converted to strict passes. The runner admits
only these specific groups and exact verdict pairs, with self-tests rejecting
different, missing or duplicate verdicts. Reports are under
`_build/interop/autobahn/reports` and the client batch directories above.

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
  pin need no network for it. The probe's connect/read timeout is 15 s,
  longer than the server's default 5 s head/body deadlines, so stalled
  requests observe the server's 408 rather than race the probe's timer.
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

Garden is managed by Compose in that external checkout, not by this runner.
After normal or interrupted work, run `./garden.sh stop` (`docker compose down`)
and verify `docker compose ps -a` is empty before restarting, so retained origin
containers do not consume the next run's memory. For concurrent sessions use
distinct `COMPOSE_PROJECT_NAME` values and the same value when stopping each
session, so cleanup does not remove another session's containers.

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

The native `ws_client` discovers every case, then echoes messages and requests
reports in the three fresh-server batches described above.
`clients/autobahn/adapter.mbtx` validates their full union and converts both
behavior and close verdicts to CASE lines. Raw reports remain in
`_build/interop/autobahn-client/{basic,12,13}/reports`.
The [upstream configuration](https://github.com/crossbario/autobahn-testsuite)
selects sections 1–7, 9, 10, 12 and 13, including permessage-deflate.
Section 9 uses explicit 64 MiB frame/message limits and a raised empty-frame
work limit. The shared adapter requires strict OK for case 2.10: the session
answers each Ping while its Pong writer is free. Only 7.1.6, 7.13.1 and
7.13.2 allow the exact INFORMATIONAL/INFORMATIONAL verdict pair.
