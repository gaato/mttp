# External private-cache comparison

The suite is [http-tests/cache-tests](https://github.com/http-tests/cache-tests),
linked by HTTPWG's testing resources, pinned to
`7e2c53785f41eedc57aa73c8cc19a6729eef39ed`. It is a comparison corpus,
not an official HTTPWG conformance certification. C7 has **not run it**.

Run from the repository root (Claude/coordinator):

```sh
MOON_CC=cc moon run conformance/cache-tests/run.mbtx
# For Docker instead of rootless Podman:
INTEROP_ENGINE=docker MOON_CC=cc moon run conformance/cache-tests/run.mbtx
```

Prerequisites: pinned MoonBit toolchain, C compiler, curl, tar, Podman or
Docker, and free loopback ports 39080 and 8000. Node runs in the digest-pinned
container used by interop/images.tsv. The runner downloads the suite's pinned
source tarball, installs dependencies without lifecycle scripts in that
container, builds the native proxy, starts the suite server, waits for both
ports, then runs the suite CLI with HTTP_PROXY and an explicit Undici
ProxyAgent preload. The runner also replaces the suite's interim-response
Agent with ProxyAgent; otherwise those tests silently bypass the proxy.
This routing-only adjustment is checked against the pinned source.
Results, installation's lockfile
and logs stay under `_build/cache-tests/`. Archive the lockfile with results;
upstream dependency ranges are not a transitive dependency lock.

The proxy accepts absolute-form HTTP requests and passes them through
`HttpCache(AsyncBackend)`; AsyncBackend includes decompression. All methods,
including PUT used by suite setup, reach the origin. It strips hop-by-hop
fields and uses streaming responses so reading to EOF exercises cache commits.
It binds only loopback, supports plaintext HTTP only, and supplies no Date
field of its own. It is a manual conformance executable outside the pure
four-target corpus; it is never run by ordinary package tests.

Review `results.json` and traces against `known.tsv`. These rows describe
expected scope differences, not failures observed in a run. Private/public,
Authorization and s-maxage must be interpreted under private-cache rules;
partial content and background SWR are deliberately unsupported. Do not mark
other failures known automatically. A zero CLI exit code means the comparison
completed, not that all tests passed; preserve individual results for review.
