#!/bin/sh
# Build the spike into out/spike.wasm (a WASI 0.3 component).
set -eu
cd "$(dirname "$0")"
moon build --target wasm "$@" >/dev/null 2>build.log || { grep -E '^Error' -A8 build.log; exit 1; }
mkdir -p out
wasm-tools component embed wit --world spike _build/wasm/debug/build/gaato/spike/gen/gen.wasm -o out/core.wasm --encoding utf16
wasm-tools parse testdata/p1_random_stub.wat -o out/p1_random_stub.wasm
wasm-tools component new out/core.wasm --adapt wasi_snapshot_preview1=out/p1_random_stub.wasm -o out/spike.wasm
