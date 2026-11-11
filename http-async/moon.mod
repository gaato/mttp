name = "gaato/http-async"

version = "0.6.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "async", "client", "server", "fetch" ]

description = "moonbitlang/core/async adapters for gaato/http: TCP and TLS connections, a client backend, a server listener, content codings and a JS fetch backend."

source = "src"

preferred_target = "native"

supported_targets = "native+wasm+js"

import {
  "gaato/mttp@0.1.0",
  "gaato/codec_bytes@0.1.1",
  "gaato/deflate@0.1.0",
  "gaato/brotli@0.4.1",
  "gaato/zstd@0.3.1",
}
