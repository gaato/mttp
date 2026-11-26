// HTTP/2 and HTTP/3 engines of gaato/mttp's own, client and server, on
// native, over the system's nghttp2, nghttp3 and ngtcp2, used without I/O:
// the sockets, timers and TLS records move on core/async, as gaato/mttp's
// HTTP/1.1 engine does. It links system libraries, so scripts/modules.tsv
// puts it in the ng gate, which only the CI jobs that install them run.

name = "gaato/mttp_ng"

version = "0.0.1"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "http2", "http3", "quic", "client", "server" ]

description = "HTTP/2 and HTTP/3 clients and servers for gaato/mttp over the system's nghttp2, nghttp3 and ngtcp2, for native."

source = "src"

preferred_target = "native"

supported_targets = "native"

import {
  "gaato/mttp_core@0.3.3",
  "gaato/mttp@0.5.2",
}

options(
  // build.js finds the libraries with pkg-config and puts them on the link
  // line of every program that links a package binding them; moon.pkg's
  // link flags would reach this module's own tests only. It runs under Node
  // when the module is built.
  "--moonbit-unstable-prebuild": "build.js",
)
