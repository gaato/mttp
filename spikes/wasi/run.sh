#!/bin/sh
# Build the spike, start the local peer, and run the component on wasmtime.
set -eu
cd "$(dirname "$0")"
./build.sh
node testdata/server.mjs 18765 &
pid=$!
trap 'kill $pid' EXIT
until curl -s 127.0.0.1:18765/hello >/dev/null; do :; done
mise exec wasmtime@51.0.0 -- wasmtime run -S http out/spike.wasm
