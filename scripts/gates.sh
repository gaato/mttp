#!/usr/bin/env bash
# Runs the repository's gates on one toolchain: the one moon on PATH runs,
# which moonbit-version pins (CI uses the image of that version; canary.yml
# runs these gates on the latest and nightly images). The modules and what
# each may depend on are listed in scripts/modules.tsv.
#
#   scripts/gates.sh quick [--target T]...  moon check --deny-warn, then the
#                                           tests of each package on its own,
#                                           on each target (default: all
#                                           four) the package builds on,
#                                           compared with the test manifest
#   scripts/gates.sh static                 moon fmt --check, moon info and
#                                           the mbti diff, the generated
#                                           sources against their
#                                           generators, the docs,
#                                           architecture, test layout,
#                                           bounds, interface and coverage
#                                           audits, the manifest's own
#                                           consistency, release.sh check
#   scripts/gates.sh full                   quick on all four targets, static,
#                                           the self-test of this script and
#                                           the resolver gate
#   scripts/gates.sh manifest --update      runs every package's tests on
#                                           every target and rewrites
#                                           scripts/test_manifest.tsv
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

static_gates() {
  step scripts/release.sh check
  # The registry index, which the .mbtx scripts and modules resolve from.
  step moon update
  step moon fmt --check
  # The scripts too, except docs_audit.mbtx: it is shared verbatim with every
  # gaato MoonBit repository and changes only there.
  local file
  for file in scripts/*.mbtx; do
    [ "$file" = scripts/docs_audit.mbtx ] || step moon fmt --check "$file"
  done
  local before after
  before=$(mbti_snapshot)
  step moon info
  after=$(mbti_snapshot)
  if [ "$before" != "$after" ]; then
    diff <(echo "$before") <(echo "$after") | grep -E '^[<>]' >&2 || true
    fail "pkg.generated.mbti was stale: 'moon info' changed it; commit the regenerated files"
  fi
  # Generated sources must match their generators byte for byte.
  step script scripts/gen_schema_objects.mbtx -- --check
  step script scripts/gen_apispec.mbtx -- --check
  step script scripts/docs_audit.mbtx --self-test
  step script scripts/architecture_gate.mbtx --self-test
  step script scripts/test_layout.mbtx --self-test
  step script scripts/bounds_check.mbtx
  step script scripts/runtime_gates.mbtx -- interfaces
  step script scripts/runtime_gates.mbtx -- manifest --check
  step script scripts/coverage_report.mbtx
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
    static_gates
    finish
    ;;
  full)
    [ $# = 0 ] || usage
    print_versions
    step script scripts/runtime_gates.mbtx -- tests
    static_gates
    step script scripts/gate_selftest.mbtx
    step script scripts/resolver_gate.mbtx -- --self-test
    step script scripts/resolver_gate.mbtx
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
