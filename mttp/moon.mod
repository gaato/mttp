// The only import is gaato/http: gaato/mttp depends on it and
// moonbitlang/core, so every package builds and tests on wasm-gc, wasm, js
// and native, and a consumer pulls no runtime, codec or crypto module into
// its graph. scripts/architecture_gate.mbtx enforces this from
// scripts/modules.tsv.

name = "gaato/mttp"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "sans-io", "client", "sse", "endpoint", "openapi" ]

description = "HTTP for MoonBit in the style of sttp, on top of gaato/http: a client with retries, rate limits and deadlines, server-sent events, multipart, cookies, endpoints and OpenAPI. Runs on every backend."

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/http@0.6.0",
}
