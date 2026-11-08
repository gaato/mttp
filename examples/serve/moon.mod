name = "gaato/mttp-example-serve"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

description = "A bounded HTTP/1 server with keep-alive and graceful shutdown."

source = "."

preferred_target = "native"

supported_targets = "native"

import {
  "gaato/http@0.6.0",
  "gaato/http-async@0.6.0",
}
