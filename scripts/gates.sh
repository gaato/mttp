#!/usr/bin/env bash
# Runs the repository's gates on one toolchain: the one moon on PATH runs,
# which moonbit-version pins (CI uses the image of that version; canary.yml
# runs these gates on the latest and nightly images). The modules and what
# each may depend on are listed in scripts/modules.tsv, whose gate column
# says which of `full` and `curl` links and tests each module. Checks that
# only read text or type-check (fmt, info, interfaces, architecture, docs)
# cover every module in both.
#
#   scripts/gates.sh quick [--target T]... [--gate G]
#                                           moon check --deny-warn, then the
#                                           tests of each package on its own,
#                                           on each target (default: all
#                                           four) the package builds on,
#                                           compared with the test manifest;
#                                           the modules of gate G (default
#                                           full)
#   scripts/gates.sh static                 moon fmt --check, moon info and
#                                           the mbti diff, the generated
#                                           sources against their
#                                           generators, the docs, the root
#                                           README against its examples,
#                                           architecture, test layout,
#                                           bounds, interface and coverage
#                                           audits, the manifest's own
#                                           consistency, release.mbtx check
#   scripts/gates.sh selftest               the self-test of this script and
#                                           the resolver gate (with its own
#                                           self-test): the parts of full
#                                           that quick, static and workerd
#                                           leave out, for CI to run them as
#                                           a job of their own
#   scripts/gates.sh workerd                the Workers example on real
#                                           workerd: builds it, installs the
#                                           wrangler its lockfile pins (npm
#                                           ci, needs the network) and runs
#                                           examples/fetch/workers/check.mjs
#   scripts/gates.sh interop                the interoperability suite: the
#                                           mttp client and server against
#                                           nginx, Caddy, Apache, curl, Go,
#                                           httpx, Node, Bun and Deno in
#                                           containers (podman or docker;
#                                           pulls images, needs the
#                                           network). Not part of full: CI
#                                           runs it daily (canary.yml).
#                                           interop/README.md says more
#   scripts/gates.sh bench [--record]       the pinned loopback transport
#                                           comparison. It prints TSV rows;
#                                           --record writes today's JSON in
#                                           benchmarks/results. CI instead
#                                           passes --output and --summary.
#   scripts/gates.sh sanitize               Linux native tests of mttp_core,
#                                           mttp and mttp_curl under ASan,
#                                           using a disposable source/toolchain
#                                           copy; needs libcurl. Daily in
#                                           canary, outside full
#   scripts/gates.sh fuzz [SECONDS]         Linux libFuzzer+ASan runs of the
#                                           fuzz/ targets (HTTP/1.1 reader,
#                                           WebSocket frame parser), SECONDS
#                                           each (default 60); needs clang
#                                           with libFuzzer (FUZZ_CC). Daily
#                                           in canary, outside full
#   scripts/gates.sh mutate [SITE]...       the hand-run HTTP/1 mutation
#                                           sample; not part of full or CI
#   scripts/gates.sh prove [--solver z3|cvc5] the number core and negative
#                                           controls, pinned solver only;
#                                           manual, outside quick/static/full
#   scripts/gates.sh apispec-corpus DIR     round-trip external OpenAPI JSON
#                                           documents through apispec. Manual
#                                           only: the documents are not ours
#                                           to redistribute and are not in CI
#   scripts/gates.sh full                   quick on all four targets, static,
#                                           the self-test of this script, the
#                                           resolver gate and workerd, for the
#                                           modules of gate full
#   scripts/gates.sh curl                   gaato/mttp_curl, which links the
#                                           system's libcurl (with HTTP/2):
#                                           its native tests, its coverage
#                                           and its resolver consumer, which
#                                           runs a program calling libcurl
#                                           (scripts/resolver_smoke/). CI runs
#                                           it as a job of its own, the one
#                                           that installs libcurl
#   scripts/gates.sh curl-live              gaato/mttp_curl's tests against
#                                           public HTTP/2 and HTTP/3 servers
#                                           (needs the internet and a libcurl
#                                           with HTTP/3)
#   scripts/gates.sh manifest --update      runs every package's tests on
#                                           every target and rewrites
#                                           scripts/test_manifest.tsv; every
#                                           gate's modules, so it needs
#                                           libcurl too
#
# This launcher is bash, unlike the .mbtx scripts beside it: it runs `moon`
# itself, on every toolchain including nightly; it filters the experimental
# warning every .mbtx prints, which a .mbtx cannot do for its own output; and
# it runs npm for the workerd gate.
set -euo pipefail
cd "$(dirname "$0")/.."

ALL_TARGETS=(wasm-gc wasm js native)
# .mbtx front matter cannot list experimental packages, so every script that
# imports moonbitlang/core/async prints this warning (see scripts/modules.tsv);
# it is dropped from script output and nothing else is.
SCRIPT_WARNING='Package `moon/test/single` depends on experimental package `moonbitlang/core/async'

failures=()
fail() { echo "FAIL: $*" >&2; failures+=("$*"); }
# Runs a command, recording a failure instead of stopping at it.
step() { echo "+ $*"; "$@" || fail "$*"; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }

# Runs a script with `moon run`, without the warning above.
script() {
  local status
  { moon run "$@" 2>&1 1>&3 3>&- | { grep -v -F "$SCRIPT_WARNING" >&2 || :; }; status=${PIPESTATUS[0]}; } 3>&1
  return "$status"
}

print_versions() {
  echo "+ moon version --all"
  moon version --all
  local pinned; pinned=$(cat moonbit-version)
  if ! moon version --all | grep -qF -- "$pinned"; then
    echo "note: moonbit-version pins $pinned; the gates run on the toolchain above" >&2
  fi
}

mbti_snapshot() {
  find . -name '*.mbti' -not -path '*/_build/*' -not -path '*/.mooncakes/*' -print0 |
    LC_ALL=C sort -z | xargs -0 -r sha256sum
}

# The committed formatting is the pinned toolchain's. Another toolchain (the
# canary's nightly row) may format the same code differently, as when a newer
# formatter adds trailing commas the pinned one removes; that is news about
# the toolchain, reported as a note, not formatting someone forgot to apply.
fmt_check() {
  if moon version --all | grep -qF -- "$(cat moonbit-version)"; then
    step moon fmt --check "$@"
  elif ! moon fmt --check "$@" >/dev/null 2>&1; then
    echo "note: 'moon fmt' on this toolchain formats ${1:-the workspace} differently from moonbit-version's" >&2
  fi
}

static_gates() {
  # The registry index, which the .mbtx scripts and modules resolve from.
  step moon update
  step script scripts/release.mbtx -- check
  fmt_check
  # Standalone tools are intentionally not in moon.work: resolve their
  # compiler/parser dependencies separately from the HTTP runtime modules.
  # Like fmt_check, formatting is enforced on the pinned toolchain only.
  if moon version --all | grep -qF -- "$(cat moonbit-version)"; then
    step moon -C mttp_schemagen fmt --check
  fi
  fmt_check mttp_schemagen/measure_shortlinks.mbtx
  # The scripts too, except docs_audit.mbtx: it is shared verbatim with every
  # gaato MoonBit repository and changes only there.
  local file
  for file in scripts/*.mbtx interop/*.mbtx; do
    [ "$file" = scripts/docs_audit.mbtx ] || fmt_check "$file"
  done
  fmt_check benchmarks/run.mbtx
  local before after
  before=$(mbti_snapshot)
  step moon info
  step moon -C mttp_schemagen info --target wasm
  after=$(mbti_snapshot)
  if [ "$before" != "$after" ]; then
    diff <(echo "$before") <(echo "$after") | grep -E '^[<>]' >&2 || true
    # The committed interfaces are the pinned toolchain's rendering. Another
    # toolchain (the canary's nightly row) may print the same API otherwise,
    # as when core renames a type; that is news about the toolchain, not
    # interfaces someone forgot to regenerate.
    if moon version --all | grep -qF -- "$(cat moonbit-version)"; then
      fail "pkg.generated.mbti was stale: 'moon info' changed it; commit the regenerated files"
    else
      echo "note: 'moon info' on this toolchain renders the interfaces above differently from moonbit-version's" >&2
    fi
  fi
  # Generated sources must match their generators byte for byte.
  step script scripts/gen_schema_objects.mbtx -- --check
  # The header records the active compiler and moonfmt output is versioned.
  # Canary compilers report their differences without rewriting pinned goldens.
  if moon version --all | grep -qF -- "$(cat moonbit-version)"; then
    step script scripts/check_schemagen.mbtx
  fi
  step script scripts/gen_apispec.mbtx -- --check
  step script scripts/gen_endpoint_maps.mbtx -- --check
  # The HTTP/1 vectors, from the upstream cases kept in conformance/data/,
  # so this check needs no checkout and no network.
  step script scripts/gen_vectors.mbtx -- --check
  step script scripts/docs_audit.mbtx --self-test
  # Copied applications need isolated builds; keep these out of quick's
  # per-package loop so each target run does not rebuild both templates.
  step script scripts/templates_gate.mbtx -- --self-test
  step script scripts/templates_gate.mbtx
  # The root README's code, outputs, links and MoonBit badge. It runs the
  # README's examples (native builds, about two seconds of retry waits),
  # cheap beside the coverage run below.
  step script scripts/readme_check.mbtx -- --self-test
  step script scripts/architecture_gate.mbtx --self-test
  step script scripts/test_layout.mbtx --self-test
  step script scripts/bounds_check.mbtx --self-test
  step script interop/run.mbtx -- --self-test
  step script scripts/runtime_gates.mbtx -- interfaces
  step script scripts/runtime_gates.mbtx -- manifest --check
  # Measuring links the modules; the curl gate measures its own.
  step script scripts/coverage_report.mbtx -- --gate full
}

# gaato/mttp_curl links the system's libcurl, so these run where it is
# installed and nowhere else; a libcurl problem cannot fail the full gate.
curl_gate() {
  step script scripts/runtime_gates.mbtx -- tests --target native --gate curl
  step script scripts/coverage_report.mbtx -- --gate curl
  step script scripts/resolver_gate.mbtx -- --gate curl
}

# The Node tests of the fetch package run the host shims under Node, which
# allows what Workers refuses (random values in global scope, for one); this
# runs the Workers entry the README shows on the runtime itself.
WORKERD_DIR=examples/fetch/workers
workerd_gate() {
  step moon build --deny-warn --target native interop/mttp_server
  step moon build --deny-warn --target js "$WORKERD_DIR"
  # wrangler runs without its dependencies' postinstall checks, and npm
  # versions differ in whether they run them unasked.
  step npm ci --prefix "$WORKERD_DIR" --ignore-scripts --no-audit --no-fund
  step node "$WORKERD_DIR/check.mjs"
}

finish() {
  if [ "${#failures[@]}" -gt 0 ]; then
    echo >&2
    echo "gates: FAILED (${#failures[@]})" >&2
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
  fi
  echo "gates: OK"
}

mode=${1:-}; shift || true
case "$mode" in
  quick)
    args=()
    gate=full
    while [ $# -gt 0 ]; do
      case "$1" in
        --target)
          t=${2:?--target needs a target}
          [[ " ${ALL_TARGETS[*]} " == *" $t "* ]] || { echo "unknown target: $t" >&2; exit 2; }
          args+=(--target "$t"); shift 2 ;;
        --gate) gate=${2:?--gate needs a gate}; shift 2 ;;
        *) usage ;;
      esac
    done
    print_versions
    step script scripts/runtime_gates.mbtx -- tests ${args[@]+"${args[@]}"} --gate "$gate"
    finish
    ;;
  static)
    [ $# = 0 ] || usage
    print_versions
    static_gates
    finish
    ;;
  full)
    [ $# = 0 ] || usage
    print_versions
    step script scripts/runtime_gates.mbtx -- tests --gate full
    static_gates
    step script scripts/gate_selftest.mbtx
    step script scripts/resolver_gate.mbtx -- --self-test
    step script scripts/resolver_gate.mbtx -- --gate full
    workerd_gate
    finish
    ;;
  selftest)
    [ $# = 0 ] || usage
    step script scripts/gate_selftest.mbtx
    step script scripts/resolver_gate.mbtx -- --self-test
    step script scripts/resolver_gate.mbtx -- --gate full
    finish
    ;;
  curl)
    [ $# = 0 ] || usage
    print_versions
    curl_gate
    finish
    ;;
  curl-live)
    [ $# = 0 ] || usage
    step env MTTP_CURL_LIVE=1 MOON_CC="${MOON_CC:-cc}" \
      moon test --deny-warn --target native mttp_curl/src/live_test.mbt
    finish
    ;;
  workerd)
    [ $# = 0 ] || usage
    workerd_gate
    finish
    ;;
  interop)
    # Extra arguments select runs by prefix, as interop/run.mbtx documents.
    step script interop/run.mbtx -- "$@"
    finish
    ;;
  bench)
    step script benchmarks/run.mbtx -- "$@"
    finish
    ;;
  sanitize)
    [ $# = 0 ] || usage
    step script scripts/sanitize.mbtx
    finish
    ;;
  fuzz)
    [ $# -le 1 ] || usage
    step script scripts/fuzz.mbtx -- "$@"
    finish
    ;;
  mutate)
    step script scripts/mutate.mbtx -- "$@"
    finish
    ;;
  prove)
    step script scripts/prove.mbtx -- "$@"
    finish
    ;;
  apispec-corpus)
    [ $# = 1 ] || usage
    step script scripts/resolver_gate.mbtx -- --run-with-local-module \
      mttp_core scripts/apispec_corpus.mbtx "$1"
    finish
    ;;
  manifest)
    [ "${1:-}" = --update ] && [ $# = 1 ] || usage
    print_versions
    step script scripts/runtime_gates.mbtx -- manifest --update
    finish
    ;;
  *) usage ;;
esac
