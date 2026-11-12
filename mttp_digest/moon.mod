name = "gaato/mttp_digest"

version = "0.3.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "digest", "auth" ]

description = "Origin-scoped Digest authentication for gaato/mttp_core."

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/mttp_core@0.1.0",
  "moonbitlang/x@0.5.7",
}
