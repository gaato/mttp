// No `import` block on purpose: gaato/http depends on nothing but
// moonbitlang/core, so every package builds and tests on wasm-gc, wasm, js
// and native. scripts/architecture_gate.mbtx enforces this from
// scripts/modules.tsv.

name = "gaato/http"

version = "0.6.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "sans-io", "http1", "codec" ]

description = "The HTTP vocabulary, a sans-IO HTTP/1.1 codec and runtime-independent client and server connection engines for MoonBit. Depends on moonbitlang/core only; runs on every backend."

source = "src"

preferred_target = "wasm-gc"
