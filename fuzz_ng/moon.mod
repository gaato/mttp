// Coverage-guided fuzz targets for gaato/mttp_ng: the HTTP/2 server
// session fed a peer's bytes, and in-memory pairs of HTTP/2 and HTTP/3
// sessions driven by a fuzzer-written program. scripts/fuzz.mbtx
// (`scripts/gates.sh fuzz --gate ng`) builds this executable's generated C,
// and the C stubs of gaato/mttp_ng beside it, with libFuzzer and ASan; the
// gates only build and run it once. A module of its own, in the ng gate, as
// interop_ng is, so that the full gate links none of the libraries.

name = "gaato/mttp-fuzz-ng"

version = "0.0.0"

source = "."

preferred_target = "native"

supported_targets = "native"

import {
  "gaato/mttp_ng@0.0.1",
}
