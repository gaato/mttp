#!/usr/bin/env bash
# Release helper for the workspace: the library modules of scripts/modules.tsv
# are released together (design, section 5.8).
#
#   scripts/release.sh bump <module> <version>   set a module's version and every
#                                                sibling import of it, and move
#                                                its CHANGELOG [Unreleased]
#                                                entries under <version> (local edit)
#   scripts/release.sh note <module> <section> <text>
#                                                add "- <text>" under ### <section>
#                                                of the module's [Unreleased]
#   scripts/release.sh check                     every module's CHANGELOG has
#                                                [Unreleased] first
#   scripts/release.sh publish --dry-run         for every module whose version
#                                                is not yet in the mooncakes
#                                                index, bottom-up: its CHANGELOG
#                                                has a heading for the version,
#                                                and `moon publish --dry-run`
#                                                accepts it
#
# This script never publishes. Publishing is an outward step that gaato
# approves each time; it is `moon -C <module> publish` for each module the dry
# run lists, in the order it lists them, with `moon update` in between so a
# dependant resolves the version published before it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Release membership is independent of target/test kind, so private harnesses
# stay tested and resolver-checked without requiring a release or changelog.
mapfile -t MODULES < <(awk -F '\t' '$8 == "yes" { print $1 }' scripts/modules.tsv)

require_release_module() {
  local module
  for module in "${MODULES[@]}"; do
    [ "$module" = "$1" ] && return 0
  done
  echo "$1 is not a release module (scripts/modules.tsv)" >&2
  exit 2
}

module_name() { sed -nE 's/^name = "(.*)"$/\1/p' "$1/moon.mod"; }
module_version() { sed -nE 's/^version = "(.*)"$/\1/p' "$1/moon.mod"; }

moon_home() { echo "${MOON_HOME:-$HOME/.moon}"; }

UNRELEASED='## [Unreleased]'

# Turns the [Unreleased] heading into [Unreleased] followed by a dated heading
# for <version>, so the entries that were under it now belong to <version>.
changelog_release() { # <module> <version>
  local file="$1/CHANGELOG.md" date; date=$(date +%F)
  [ -f "$file" ] || return 0
  if ! grep -qxF "$UNRELEASED" "$file"; then
    echo "warning: $file has no '$UNRELEASED' heading; not updated" >&2; return 0
  fi
  if grep -qF "## [$2] - " "$file"; then
    echo "  $file already has [$2]"; return 0
  fi
  awk -v u="$UNRELEASED" -v v="## [$2] - $date" '
    $0 == u { print; print ""; print v; inside = 1; next }
    inside && /^## / { inside = 0 }
    inside && NF { entries = 1 }
    { print }
    END { if (!entries) print "warning: no entries under [Unreleased] for " v > "/dev/stderr" }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  echo "  $file: [Unreleased] -> [$2] - $date"
}

# Appends "- <text>" to ### <section> of [Unreleased], creating the section.
changelog_note() { # <module> <section> <text>
  local file="$1/CHANGELOG.md"
  [ -f "$file" ] || { echo "no $file" >&2; exit 1; }
  grep -qxF "$UNRELEASED" "$file" || { echo "$file has no '$UNRELEASED' heading" >&2; exit 1; }
  awk -v u="$UNRELEASED" -v sec="### $2" -v entry="- $3" '
    { line[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) if (line[i] == u) { start = i; break }
      end = n + 1
      for (i = start + 1; i <= n; i++) if (line[i] ~ /^## /) { end = i; break }
      s = 0
      for (i = start + 1; i < end; i++) if (line[i] == sec) { s = i; break }
      if (s) {
        stop = end
        for (i = s + 1; i < end; i++) if (line[i] ~ /^##/) { stop = i; break }
        last = stop - 1; while (last > s && line[last] == "") last--
        for (i = 1; i <= last; i++) print line[i]
        if (last == s) print ""
        print entry
        for (i = last + 1; i <= n; i++) print line[i]
      } else {
        last = end - 1; while (last > start && line[last] == "") last--
        for (i = 1; i <= last; i++) print line[i]
        print ""; print sec; print ""; print entry
        if (end <= n) print ""
        for (i = end; i <= n; i++) print line[i]
      }
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

index_has() { # <name> <version>
  local file="$(moon_home)/registry/index/user/$1.index"
  [ -f "$file" ] && grep -Eq "\"version\"[[:space:]]*:[[:space:]]*\"$2\"" "$file"
}

cmd=${1:-}; shift || true
case "$cmd" in
  bump)
    module=${1:?module}; version=${2:?version}
    require_release_module "$module"
    name=$(module_name "$module")
    sed -i -E "s/^version = \".*\"$/version = \"$version\"/" "$module/moon.mod"
    for mod in */moon.mod; do
      sed -i -E "s|\"$name@[0-9][^\"]*\"|\"$name@$version\"|" "$mod"
    done
    echo "$name -> $version"; { grep -l "$name@$version" */moon.mod || true; } | sed 's/^/  /'
    changelog_release "$module" "$version"
    ;;
  note)
    changelog_note "${1:?module}" "${2:?section}" "${3:?text}"
    ;;
  check)
    status=0
    for module in "${MODULES[@]}"; do
      file="$module/CHANGELOG.md"
      if [ ! -f "$file" ]; then
        echo "$file is missing" >&2; status=1; continue
      fi
      if [ "$(grep -m1 '^## ' "$file")" != "$UNRELEASED" ]; then
        echo "$file: the first section must be '$UNRELEASED'" >&2; status=1
      fi
    done
    [ "$status" = 0 ] && echo "release check: OK (${#MODULES[@]} changelogs)"
    exit "$status"
    ;;
  publish)
    if [ "${1:-}" != "--dry-run" ] || [ $# != 1 ]; then
      echo "release.sh publishes nothing; run 'scripts/release.sh publish --dry-run'" >&2
      exit 2
    fi
    moon update >/dev/null
    pending=()
    status=0
    for module in "${MODULES[@]}"; do
      name=$(module_name "$module"); version=$(module_version "$module")
      if index_has "$name" "$version"; then
        echo "skip    $name@$version (already published)"; continue
      fi
      if ! grep -qF "## [$version] - " "$module/CHANGELOG.md"; then
        echo "$module/CHANGELOG.md: no '## [$version] - <date>' heading (use 'scripts/release.sh bump')" >&2
        status=1
      fi
      # A dependant of a module that this run would publish first cannot be
      # checked yet: its packaged copy resolves dependencies from the
      # registry. moon says "not found in the registry" for a module that was
      # never published and "no version satisfies" for a new version of one
      # that was.
      if out=$(moon -C "$module" publish --dry-run 2>&1) || echo "$out" | grep -q 'Dry run completed successfully'; then
        echo "would   $name@$version"
      elif [ "${#pending[@]}" -gt 0 ] && echo "$out" | grep -qE "dependency \`($(IFS='|'; echo "${pending[*]}"))\`.*(not found in the registry|no version satisfies)"; then
        echo "would   $name@$version (after ${pending[*]}; not checkable before they exist)"
      else
        echo "$out"; status=1
      fi
      pending+=("$name")
    done
    exit "$status"
    ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
