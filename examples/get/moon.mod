name = "gaato/mttp-example-get"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

description = "A bounded HTTP GET using the asynchronous backend."

source = "."

preferred_target = "native"

supported_targets = "native+wasm"

import {
  "gaato/http@0.6.0",
  "gaato/http-async@0.6.0",
}
