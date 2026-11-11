name = "gaato/mttp_async"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "client", "server", "retry", "openapi", "async" ]

description = "HTTP for MoonBit apps that outgrow the built-in client: one module with a ready client (retries with a budget, deadlines, redirects, decompression) and a server, on moonbitlang/core/async for native, wasm and js. Libraries depend on gaato/mttp instead."

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
