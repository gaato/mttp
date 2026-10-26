#!/usr/bin/env bash
# Runs the repository's gates on one toolchain: the one moon on PATH runs,
# which moonbit-version pins to the latest MoonBit release (CI uses the image
# of that version; canary.yml runs these gates on the latest and nightly
# images).
#
#   scripts/gates.sh quick [--target T]...  for every four-target module and
#                                           target (default: all four):
#                                           moon check --deny-warn, then the
#                                           tests of each package on its own,
#                                           compared with the test manifest
#   scripts/gates.sh static                 moon fmt --check, moon info and
#                                           the mbti diff, the docs, test
#                                           layout and bounds audits, the
#                                           manifest's own consistency,
#                                           release.sh check
#   scripts/gates.sh full                   quick on all four targets, then
#                                           static
#   scripts/gates.sh manifest --update      runs every package's tests on all
#                                           four targets and rewrites
#                                           scripts/test_manifest.tsv
#
# Tests run one package per `moon test` so that a native abort, which kills
# the whole test binary, cannot hide the results of other packages. A run
# fails when `moon test` fails, when it prints no "Total tests" line, or when
# it reports 0 tests for a package the manifest does not record with 0.
set -euo pipefail
cd "$(dirname "$0")/.."

ALL_TARGETS=(wasm-gc js native wasm)
# Workspace members whose every package builds and tests on all four targets.
FOUR_TARGET_MODULES=(mttp mttp-digest conformance)
# Modules whose test counts must be equal on all four targets.
EQUAL_COUNT_MODULES=(gaato/mttp gaato/mttp-digest gaato/mttp-conformance)
MANIFEST=scripts/test_manifest.tsv
MANIFEST_HEADER=$'module\tpackage\ttarget\tcount'
WORK=_build/gates
TEST_TIMEOUT=${GATES_TEST_TIMEOUT:-600}

failures=()
fail() { echo "FAIL: $*" >&2; failures+=("$*"); }
# Runs a command, recording a failure instead of stopping at it.
step() { echo "+ $*"; "$@" || fail "$*"; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }

module_name() { sed -nE 's/^name = "(.*)"$/\1/p' "$1/moon.mod"; }

# The package directories of a module, sorted.
package_dirs() {
  find "$1/src" -name moon.pkg -not -path '*/_build/*' -not -path '*/.mooncakes/*' -printf '%h\n' |
    LC_ALL=C sort
}

package_name() { # <module dir> <package dir>
  echo "$(module_name "$1")${2#"$1/src"}"
}

# Every package of the four-target modules, as "module<TAB>package<TAB>dir".
all_packages() {
  local mdir dir
  for mdir in "${FOUR_TARGET_MODULES[@]}"; do
    while IFS= read -r dir; do
      printf '%s\t%s\t%s\n' "$(module_name "$mdir")" "$(package_name "$mdir" "$dir")" "$dir"
    done < <(package_dirs "$mdir")
  done
}

# The manifest's rows without the header and comments.
manifest_rows() {
  [ -f "$MANIFEST" ] || return 0
  grep -v -e '^#' -e $'^module\t' -e '^$' "$MANIFEST" || true
}

manifest_count() { # <module> <package> <target>
  manifest_rows | awk -F'\t' -v m="$1" -v p="$2" -v t="$3" '$1 == m && $2 == p && $3 == t { print $4 }'
}

print_versions() {
  echo "+ moon version --all"
  moon version --all
  local pinned; pinned=$(cat moonbit-version)
  if ! moon version --all | grep -qF -- "$pinned"; then
    echo "note: moonbit-version pins $pinned; the gates run on the toolchain above" >&2
  fi
}

# Runs one package's tests on one target and appends its count to
# $WORK/counts.tsv. <zero> is "manifest" (0 tests only where the manifest
# records 0) or "any".
test_package() { # <module> <package> <dir> <target> <zero>
  local module=$1 pkg=$2 dir=$3 target=$4 zero=$5
  local log="$WORK/log/$target/${pkg//\//__}.log" status=0 total
  mkdir -p "$(dirname "$log")"
  echo "+ moon test --target $target $dir"
  timeout "$TEST_TIMEOUT" moon test --target "$target" "$dir" >"$log" 2>&1 || status=$?
  total=$(grep -Eo 'Total tests: [0-9]+' "$log" | tail -n1 | grep -Eo '[0-9]+$' || true)
  if [ "$status" != 0 ]; then
    cat "$log" >&2
    fail "$pkg on $target: moon test exited with status $status"
    return 0
  fi
  if [ -z "$total" ]; then
    cat "$log" >&2
    fail "$pkg on $target: no 'Total tests' line"
    return 0
  fi
  if [ "$total" = 0 ] && [ "$zero" = manifest ] && [ "$(manifest_count "$module" "$pkg" "$target")" != 0 ]; then
    cat "$log" >&2
    fail "$pkg on $target: 0 tests, and $MANIFEST does not record 0 for it"
  fi
  echo "  $total tests"
  printf '%s\t%s\t%s\t%s\n' "$module" "$pkg" "$target" "$total" >>"$WORK/counts.tsv"
}

# check --deny-warn and the tests of every package on each target.
run_targets() { # <zero> <target>...
  local zero=$1; shift
  local target module pkg dir dirs
  mkdir -p "$WORK"; : >"$WORK/counts.tsv"
  mapfile -t dirs < <(all_packages | cut -f3)
  for target in "$@"; do
    step moon check --deny-warn --no-mbti --target "$target" "${dirs[@]}"
    while IFS=$'\t' read -r module pkg dir; do
      test_package "$module" "$pkg" "$dir" "$target" "$zero"
    done < <(all_packages)
  done
}

# The counts of this run against the manifest's rows for the same targets.
compare_manifest() { # <target>...
  local targets=" $* " expected actual
  expected=$(manifest_rows | awk -F'\t' -v ts="$targets" 'index(ts, " " $3 " ")' | LC_ALL=C sort)
  actual=$(LC_ALL=C sort "$WORK/counts.tsv")
  if [ "$expected" != "$actual" ]; then
    echo "test counts differ from $MANIFEST (- manifest, + this run):" >&2
    diff <(echo "$expected") <(echo "$actual") | grep -E '^[<>]' | sed 's/^</-/; s/^>/+/' >&2 || true
    fail "test counts differ from $MANIFEST; if the change is intended, run 'scripts/gates.sh manifest --update'"
  else
    echo "test counts match $MANIFEST ($(echo "$actual" | grep -c . || true) package-target rows)"
  fi
}

# The manifest on its own: well formed, one row per current package and
# target, and equal counts across the targets where they must be.
check_manifest_file() {
  echo "+ check $MANIFEST"
  if [ ! -f "$MANIFEST" ]; then
    fail "$MANIFEST is missing; run 'scripts/gates.sh manifest --update'"; return 0
  fi
  if [ "$(grep -v '^#' "$MANIFEST" | head -n1)" != "$MANIFEST_HEADER" ]; then
    fail "$MANIFEST: the first row must be the header '$MANIFEST_HEADER'"
  fi
  local bad
  bad=$(manifest_rows | awk -F'\t' 'NF != 4 || $4 !~ /^[0-9]+$/ { print "  malformed: " $0 } { k = $1 FS $2 FS $3; if (seen[k]++) print "  duplicate: " $0 }')
  [ -z "$bad" ] || { echo "$bad" >&2; fail "$MANIFEST has malformed or duplicate rows"; }
  local expected recorded module pkg target
  expected=$(all_packages | while IFS=$'\t' read -r module pkg _; do
    for target in "${ALL_TARGETS[@]}"; do printf '%s\t%s\t%s\n' "$module" "$pkg" "$target"; done
  done | LC_ALL=C sort)
  recorded=$(manifest_rows | cut -f1-3 | LC_ALL=C sort)
  if [ "$expected" != "$recorded" ]; then
    echo "package-target rows differ from the packages in the tree (- tree, + manifest):" >&2
    diff <(echo "$expected") <(echo "$recorded") | grep -E '^[<>]' | sed 's/^</-/; s/^>/+/' >&2 || true
    fail "$MANIFEST does not list every package on every target; run 'scripts/gates.sh manifest --update'"
  fi
  for module in "${EQUAL_COUNT_MODULES[@]}"; do
    bad=$(manifest_rows | awk -F'\t' -v m="$module" '$1 == m {
        if (!($2 in first)) first[$2] = $4; else if (first[$2] != $4) diff[$2] = 1
        line[$2] = line[$2] " " $3 "=" $4
      }
      END { for (p in diff) print "  " p ":" line[p] }')
    [ -z "$bad" ] || { echo "$bad" >&2; fail "$module: test counts differ across targets"; }
  done
}

mbti_snapshot() {
  find . -name '*.mbti' -not -path '*/_build/*' -not -path '*/.mooncakes/*' -print0 |
    LC_ALL=C sort -z | xargs -0 -r sha256sum
}

static_gates() {
  step scripts/release.sh check
  # The registry index, which the .mbtx scripts need to resolve their imports.
  step moon update
  step moon fmt --check
  # The scripts too, except docs_audit.mbtx: it is shared verbatim with every
  # gaato MoonBit repository and changes only there.
  local script
  for script in scripts/*.mbtx; do
    [ "$script" = scripts/docs_audit.mbtx ] || step moon fmt --check "$script"
  done
  local before after
  before=$(mbti_snapshot)
  step moon info
  after=$(mbti_snapshot)
  if [ "$before" != "$after" ]; then
    diff <(echo "$before") <(echo "$after") | grep -E '^[<>]' >&2 || true
    fail "pkg.generated.mbti was stale: 'moon info' changed it; commit the regenerated files"
  fi
  step moon run scripts/docs_audit.mbtx --self-test
  step moon run scripts/test_layout.mbtx --self-test
  step moon run scripts/bounds_check.mbtx
  step moon run scripts/runtime_gates.mbtx
  step moon run scripts/architecture_gate.mbtx
  step moon run scripts/type_contracts.mbtx
  step moon run scripts/coverage_report.mbtx
  check_manifest_file
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
    targets=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --target) targets+=("${2:?--target needs a target}"); shift 2 ;;
        *) usage ;;
      esac
    done
    [ "${#targets[@]}" -gt 0 ] || targets=("${ALL_TARGETS[@]}")
    for t in "${targets[@]}"; do
      [[ " ${ALL_TARGETS[*]} " == *" $t "* ]] || { echo "unknown target: $t" >&2; exit 2; }
    done
    print_versions
    run_targets manifest "${targets[@]}"
    compare_manifest "${targets[@]}"
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
    run_targets manifest "${ALL_TARGETS[@]}"
    compare_manifest "${ALL_TARGETS[@]}"
    static_gates
    finish
    ;;
  manifest)
    [ "${1:-}" = --update ] && [ $# = 1 ] || usage
    print_versions
    run_targets any "${ALL_TARGETS[@]}"
    if [ "${#failures[@]}" -gt 0 ]; then
      echo "not rewriting $MANIFEST: fix the failures first" >&2
      finish
    fi
    {
      echo "# Tests per package and target, compared by scripts/gates.sh. Regenerate"
      echo "# with 'scripts/gates.sh manifest --update' after adding or removing tests."
      echo "$MANIFEST_HEADER"
      LC_ALL=C sort "$WORK/counts.tsv"
    } >"$MANIFEST"
    echo "wrote $MANIFEST"
    check_manifest_file
    finish
    ;;
  *) usage ;;
esac
