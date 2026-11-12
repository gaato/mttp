#!/usr/bin/env bash
# Runs the repository's gates on one toolchain: the one moon on PATH runs,
# which moonbit-version pins (CI uses the image of that version; canary.yml
# runs these gates on the latest and nightly images). The modules and what
# each may depend on are listed in scripts/modules.tsv; its `gate` column says
# which of `full` and `moonfetch` builds, tests, measures and packages each.
#
#   scripts/gates.sh quick [--target T]... [--gate G]
#                                           moon check --deny-warn, then the
#                                           tests of each package on its own,
#                                           on each target (default: all
#                                           four) the package builds on,
#                                           compared with the test manifest;
#                                           every module, or those of gate G
#   scripts/gates.sh static                 full's static gates: moon fmt
#                                           --check, moon info and the mbti
#                                           diff, the generated sources
#                                           against their generators, the
#                                           docs, the root README against its
#                                           examples, architecture, test
#                                           layout, bounds, interface and
#                                           coverage audits, the manifest's
#                                           own consistency, release.mbtx check
#   scripts/gates.sh workerd                the Workers example on real
#                                           workerd: builds it, installs the
#                                           wrangler its lockfile pins (npm
#                                           ci, needs the network) and runs
#                                           examples/fetch/workers/check.mjs
#   scripts/gates.sh full                   the modules of gate full (all but
#                                           gaato/mttp_moonfetch): quick on
#                                           all four targets, static, the
#                                           self-test of this script, the
#                                           resolver gate and workerd
#   scripts/gates.sh moonfetch              gaato/mttp_moonfetch: its tests on
#                                           native and wasm, moon fmt --check,
#                                           moon info and the mbti diff, the
#                                           interface and coverage audits and
#                                           the resolver gate for it. No test
#                                           needs the network.
#   scripts/gates.sh all                    full, then moonfetch (for local
#                                           runs; CI runs them as two jobs)
#   scripts/gates.sh live                   gaato/mttp_moonfetch's tests
#                                           against public HTTP/2 and HTTP/3
#                                           servers, on native. They need the
#                                           internet, so only canary.yml runs
#                                           them.
#   scripts/gates.sh newest                 mttp_moonfetch/moon.mod raised to
#                                           the newest moonbitstack/moonfetch
#                                           and moonbitlang/async on
#                                           mooncakes.io, then moonfetch and
#                                           live; moon.mod is restored
#                                           afterwards
#   scripts/gates.sh manifest --update      runs every package's tests on
#                                           every target and rewrites
#                                           scripts/test_manifest.tsv
#
# The checks that only read text (architecture, test layout, docs, bounds,
# the manifest's own consistency, release.mbtx check) cover every module in
# both full and moonfetch. Everything that compiles is split by gate, so a
# toolchain change or a moonbitstack release that breaks mttp_moonfetch's
# dependencies fails moonfetch alone.
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
# The module of the moonfetch gate, for live and newest.
MOONFETCH_DIR=mttp_moonfetch

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

# The interfaces of the given package directories, missing ones included, so
# a package that gains or loses one shows up too.
mbti_snapshot() {
  local dir
  for dir in "$@"; do
    if [ -f "$dir/pkg.generated.mbti" ]; then
      sha256sum "$dir/pkg.generated.mbti"
    else
      echo "no interface: $dir"
    fi
  done
}

# The static gates of gate $1 (full or moonfetch).
static_gates() {
  local gate=$1
  # The registry index, which the .mbtx scripts and modules resolve from.
  step moon update
  local packages=()
  local listed
  if listed=$(script scripts/runtime_gates.mbtx -- packages --gate "$gate"); then
    mapfile -t packages <<<"$listed"
  else
    fail "runtime_gates.mbtx packages --gate $gate"
    return
  fi
  step script scripts/release.mbtx -- check
  step moon fmt --check "${packages[@]}"
  if [ "$gate" = full ]; then
    # The scripts too, except docs_audit.mbtx: it is shared verbatim with
    # every gaato MoonBit repository and changes only there.
    local file
    for file in scripts/*.mbtx; do
      [ "$file" = scripts/docs_audit.mbtx ] || step moon fmt --check "$file"
    done
  fi
  local before after
  before=$(mbti_snapshot "${packages[@]}")
  step moon info "${packages[@]}"
  after=$(mbti_snapshot "${packages[@]}")
  if [ "$before" != "$after" ]; then
    diff <(echo "$before") <(echo "$after") | grep -E '^[<>]' >&2 || true
    fail "pkg.generated.mbti was stale: 'moon info' changed it; commit the regenerated files"
  fi
  if [ "$gate" = full ]; then
    # Generated sources must match their generators byte for byte.
    step script scripts/gen_schema_objects.mbtx -- --check
    step script scripts/gen_apispec.mbtx -- --check
    step script scripts/gen_endpoint_maps.mbtx -- --check
  fi
  step script scripts/docs_audit.mbtx --self-test
  if [ "$gate" = full ]; then
    # The root README's code, outputs, links and MoonBit badge. It runs the
    # README's examples (native builds, about two seconds of retry waits),
    # cheap beside the coverage run below.
    step script scripts/readme_check.mbtx -- --self-test
  fi
  step script scripts/architecture_gate.mbtx --self-test
  step script scripts/test_layout.mbtx --self-test
  step script scripts/bounds_check.mbtx
  step script scripts/runtime_gates.mbtx -- interfaces --gate "$gate"
  step script scripts/runtime_gates.mbtx -- manifest --check
  step script scripts/coverage_report.mbtx -- --gate "$gate"
}

full_gate() {
  step script scripts/runtime_gates.mbtx -- tests --gate full
  static_gates full
  step script scripts/gate_selftest.mbtx
  step script scripts/resolver_gate.mbtx -- --self-test
  step script scripts/resolver_gate.mbtx -- --gate full
  workerd_gate
}

moonfetch_gate() {
  step script scripts/runtime_gates.mbtx -- tests --gate moonfetch
  static_gates moonfetch
  step script scripts/resolver_gate.mbtx -- --gate moonfetch
}

# The tests against public servers return at once unless MTTP_MOONFETCH_LIVE
# is set, so the other gates count them without reaching the network.
live_gate() {
  step env MTTP_MOONFETCH_LIVE=1 MOON_CC="${MOON_CC:-cc}" \
    moon test --deny-warn --target native "$MOONFETCH_DIR/src/live_test.mbt"
}

newest_gate() {
  local saved
  saved=$(mktemp)
  cp "$MOONFETCH_DIR/moon.mod" "$saved"
  # shellcheck disable=SC2064 # expand now: $saved is local
  trap "cp '$saved' '$MOONFETCH_DIR/moon.mod'; rm -f '$saved'" EXIT
  step moon update
  # `moon add` records the newest version of each; minimal version selection
  # then lifts moonfetch's own dependencies with it.
  step moon -C "$MOONFETCH_DIR" add --upgrade moonbitstack/moonfetch
  step moon -C "$MOONFETCH_DIR" add --upgrade moonbitlang/async
  grep -E '"(moonbitstack/moonfetch|moonbitlang/async)@' "$MOONFETCH_DIR/moon.mod" || true
  moonfetch_gate
  live_gate
}

# The Node tests of the fetch package run the host shims under Node, which
# allows what Workers refuses (random values in global scope, for one); this
# runs the Workers entry the README shows on the runtime itself.
WORKERD_DIR=examples/fetch/workers
workerd_gate() {
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
    while [ $# -gt 0 ]; do
      case "$1" in
        --target)
          t=${2:?--target needs a target}
          [[ " ${ALL_TARGETS[*]} " == *" $t "* ]] || { echo "unknown target: $t" >&2; exit 2; }
          args+=(--target "$t"); shift 2 ;;
        --gate)
          args+=(--gate "${2:?--gate needs a gate}"); shift 2 ;;
        *) usage ;;
      esac
    done
    print_versions
    step script scripts/runtime_gates.mbtx -- tests ${args[@]+"${args[@]}"}
    finish
    ;;
  static)
    [ $# = 0 ] || usage
    print_versions
    static_gates full
    finish
    ;;
  full | moonfetch | all | live | newest | workerd)
    [ $# = 0 ] || usage
    print_versions
    case "$mode" in
      full) full_gate ;;
      moonfetch) moonfetch_gate ;;
      all) full_gate; moonfetch_gate ;;
      live) live_gate ;;
      newest) newest_gate ;;
      workerd) workerd_gate ;;
    esac
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
