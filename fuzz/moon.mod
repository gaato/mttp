// Coverage-guided fuzz targets for the HTTP/1.1 reader and the WebSocket
// frame parser. scripts/fuzz.mbtx (`scripts/gates.sh fuzz`) builds this
// executable's generated C with libFuzzer and ASan; the gates only build it.
name = "gaato/mttp-fuzz"

version = "0.0.0"

source = "."

preferred_target = "native"

supported_targets = "native"

import {
  "gaato/mttp_core@0.3.1",
}
