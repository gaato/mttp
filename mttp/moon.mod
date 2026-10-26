// No `import` block on purpose: gaato/mttp depends on nothing but
// moonbitlang/core, so every package builds and tests on wasm-gc, wasm, js
// and native, and a consumer pulls no runtime, codec or crypto module into
// its graph. Anything that needs a socket or an async runtime lives in a
// sibling module (see ../moon.work); scripts/test_layout.mbtx enforces this.

name = "gaato/mttp"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "sans-io", "client", "sse", "endpoint", "openapi" ]

description = "Sans-IO HTTP for MoonBit in the style of sttp: a wire vocabulary, a client with retries and rate limits, server-sent events, multipart, and deterministic test doubles. No dependencies; runs on every backend."

source = "src"

preferred_target = "wasm-gc"
