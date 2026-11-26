// gaato/mttp_ng's servers and clients driven against third-party HTTP/2 and
// HTTP/3 implementations (h2spec, curl, nghttp2's and ngtcp2's tools). A
// module of its own, in the ng gate, so that the interop suite of the full
// gate does not link nghttp2, nghttp3 and ngtcp2.

name = "gaato/mttp-interop-ng"

version = "0.1.0"

license = "Apache-2.0"

description = "The interoperability programs of gaato/mttp_ng: a server for h2spec and other HTTP/2 and HTTP/3 peers."

source = "."

preferred_target = "native"

supported_targets = "native"

import {
  "gaato/mttp_core@0.3.2",
  "gaato/mttp@0.5.2",
  "gaato/mttp_ng@0.0.1",
}
