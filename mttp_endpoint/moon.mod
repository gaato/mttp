// gaato/mttp_endpoint is its own module so that the endpoint layer can change
// on its own 0.x cadence without moving gaato/mttp, which the SDKs build on.
// It imports gaato/http and gaato/mttp only; scripts/architecture_gate.mbtx
// enforces this from scripts/modules.tsv.

name = "gaato/mttp_endpoint"

version = "0.1.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mttp"

keywords = [ "http", "endpoint", "router", "openapi", "sans-io" ]

description = "Typed HTTP endpoints for MoonBit in the style of tapir, on gaato/mttp: one definition gives a client call, a server handler and an OpenAPI document. Runs on every backend."

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/http@0.6.0",
  "gaato/mttp@0.1.0",
}
