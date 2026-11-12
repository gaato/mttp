// gaato/mttp's Backend over moonbitstack/moonfetch: HTTP/1.1 and HTTP/2 by
// ALPN and, when asked, HTTP/3 under mttp's Client. The policies (redirects,
// retries, cookies, deadlines) stay in gaato/mttp; this module only moves
// bytes. It is the one module of the repository on the registry's
// moonbitlang/async; scripts/architecture_gate.mbtx keeps that dependency
// here and its floor at 0.22.6.

name = "gaato/mttp_moonfetch"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "http2", "http3", "client", "backend", "async" ]

description = "An HTTP/2 and HTTP/3 backend for gaato/mttp's Client on moonbitstack/moonfetch, for native and wasm. Experimental."

source = "src"

preferred_target = "native"

supported_targets = "native+wasm"

import {
  "gaato/mttp@0.1.0",
  "gaato/mttp_async@0.1.0",
  "moonbitstack/moonfetch@0.1.8",
  "moonbitstack/moonhttp@0.15.10",
  "moonbitstack/moontls@0.9.16",
  "moonbitstack/mooncred@0.6.13",
  "moonbitstack/moonnet@0.1.12",
  // moonfetch runs on the registry's moonbitlang/async, gaato/mttp_async on
  // moonbitlang/core/async. From 0.22.6 the registry module runs on
  // core/async's event loop, so both share one runtime; moonfetch asks for
  // 0.22.5, and minimal version selection takes this higher floor.
  "moonbitlang/async@0.22.9",
}
