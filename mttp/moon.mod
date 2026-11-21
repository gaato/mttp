name = "gaato/mttp"

version = "0.5.1"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "client", "server", "retry", "sse", "async" ]

description = "HTTP for MoonBit apps that outgrow the built-in client: the module an app starts with, holding a ready client (retries with a budget, deadlines, redirects, cookies, decompression) and a server, on moonbitlang/core/async for native, wasm and js. Typed endpoints and OpenAPI come from gaato/mttp_core, which libraries depend on instead."

source = "src"

preferred_target = "native"

supported_targets = "native+wasm+js"

import {
  "gaato/mttp_core@0.3.2",
  "gaato/codec_bytes@0.1.2",
  "gaato/deflate@0.4.0",
  "gaato/brotli@0.5.0",
  "gaato/zstd@0.6.0",
}
