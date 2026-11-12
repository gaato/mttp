// gaato/mttp_core has no imports: it depends only on moonbitlang/core, so every
// package builds and tests on wasm-gc, wasm, js and native, and a consumer
// pulls no runtime, codec or crypto module into its graph. scripts/architecture_gate.mbtx enforces this from
// scripts/modules.tsv.

name = "gaato/mttp_core"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [
  "http",
  "client",
  "server",
  "router",
  "sans-io",
  "openapi",
  "endpoint",
  "sse",
]

description = "HTTP for MoonBit without I/O, for libraries such as SDKs: the types, an HTTP/1.1 codec and engines, a client with retries under a budget, deadlines, rate limits, redirects and cookies, SSE, multipart, and typed endpoints with a router and OpenAPI. Apps add gaato/mttp."

source = "src"

preferred_target = "wasm-gc"
