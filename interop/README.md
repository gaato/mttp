# Interoperability suite

Most of mttp's tests are self-consistent: the mttp client against the mttp
server, or against recorded bytes. Two implementations that share a
misunderstanding pass those. This suite runs mttp against widely used
third-party implementations instead:

- **The client** (`gaato/mttp_async`'s Client and backend,
  [mttp_client](mttp_client/main.mbt)) against nginx, Caddy and Apache
  httpd, over HTTP/1.1 and TLS, natively and as js under Node, Bun and Deno.
  It checks keep-alive reuse, a server closing an idle connection first,
  chunked responses, the content codings each server produces itself
  (gzip everywhere, zstd from Caddy, Brotli from Apache), HEAD, 204 and 304,
  301/302/307/308 redirects with credentials dropped across origins and no
  HTTPS-to-HTTP downgrade, `Expect: 100-continue` uploads and early refusals,
  16 MiB downloads and 8 MiB uploads, chunked uploads, trickled bodies and
  the client's deadlines, and a server that closes without answering.
- **The server** (`gaato/mttp_async`'s server,
  [mttp_server](mttp_server/main.mbt)) driven by curl, Go's net/http, Python
  httpx, and the fetch of Node, Bun and Deno ([clients](clients)), directly
  and behind nginx, Caddy and Apache as reverse proxies. It checks
  connection reuse (also through each proxy's upstream pool), chunked and
  large request bodies, `Expect: 100-continue`, streamed responses, HEAD and
  204, concurrent requests, HTTP/1.0, pipelining, and request smuggling
  shapes from raw sockets ([probes.py](clients/python/probes.py)): sent
  directly they must be refused as [CONTRACT.md](../CONTRACT.md) says, and
  through a proxy, whatever reaches the server must be unambiguous.

[cases.tsv](cases.tsv) lists every case, where it runs and what it expects;
the server configurations are in [servers](servers). Every third-party
program runs from an image pinned by digest in [images.tsv](images.tsv), and
httpx is pinned with hashes in
[requirements.txt](clients/python/requirements.txt).

## Running it

From the repository root:

```sh
scripts/gates.sh interop
```

or `moon run interop/run.mbtx`, with an optional prefix to run part of it,
such as `moon run interop/run.mbtx -- client/native/apache` or `-- server/raw`.
It needs podman or docker (podman is preferred; `INTEROP_ENGINE` chooses),
openssl, a C compiler for moon's native target, and ports 39000, 39010,
39011, 39020, 39021, 39030 and 39031 free on 127.0.0.1 and 127.0.0.2. A run
takes a few minutes once the images are pulled. CI runs it daily, in the
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
