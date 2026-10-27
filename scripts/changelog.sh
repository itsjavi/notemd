#!/usr/bin/env bash
# CHANGELOG.md from Conventional Commits: each release's section is its notes on GitHub and in Sparkle's
# update window.
#
#   scripts/changelog.sh add <version>                   # prepends <version>'s section (make bump does this)
#   scripts/changelog.sh section <version> [<from> <to>] # prints a section without writing it
#   scripts/changelog.sh notes <version>                 # prints <version>'s section body (release notes)
#
# A section lists the commits since the previous release (a stable release counts from the previous stable
# one, so it includes its pre-releases' changes) to HEAD, or from <from> to <to>: breaking changes (`feat!:`,
# `BREAKING CHANGE:`), then feat, fix and perf. Other types (chore, build, ci, docs, refactor, style, test)
# are left out. Backfill older releases with `section <version> <previous tag> <tag>` (empty <from> for the
# first one).
#
# Runs on macOS's bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="NoteMD"
CHANGELOG=CHANGELOG.md
HEADER="# Changelog

Notable changes in each $APP_NAME release, written from its commit messages by \`scripts/changelog.sh\`."

usage() { sed -n '5,7s/^# \{0,1\}//p' "$0" >&2; exit 64; }
fail() { echo "✗ $*" >&2; exit 1; }

# Prints the section of $1 for the commits in $2..$3 ($2 empty: the whole history), dated $4.
section() {
  local version="$1" from="$2" to="$3" date="$4"
  local breaking="" features="" fixes="" performance=""
  local range="$to"
  if [ -n "$from" ]; then range="$from..$to"; fi
  local hash subject body type scope bang text line
  # One record per commit: hash, subject and body separated by \x1f, records ended by \x1e.
  while IFS=$'\x1f' read -r -d $'\x1e' hash subject body; do
    hash="${hash#$'\n'}"
    [[ "$subject" =~ ^([a-z]+)(\(([^\)]+)\))?(!)?:\ (.+)$ ]] || continue
    type="${BASH_REMATCH[1]}" scope="${BASH_REMATCH[3]}" bang="${BASH_REMATCH[4]}" text="${BASH_REMATCH[5]}"
    line="- ${scope:+**$scope:** }$text ($hash)"
    if [ -n "$bang" ] || printf '%s\n' "$body" | grep -qE '^BREAKING[ -]CHANGE:'; then
      breaking+="$line"$'\n'
    else
      case "$type" in
        feat) features+="$line"$'\n' ;;
        fix) fixes+="$line"$'\n' ;;
        perf) performance+="$line"$'\n' ;;
      esac
    fi
  done < <(git log --no-merges --format='%h%x1f%s%x1f%b%x1e' "$range")

  printf '## %s (%s)\n' "$version" "$date"
  if [ -z "$breaking$features$fixes$performance" ]; then
    printf '\nNo notable changes.\n'
    return
  fi
  local group
  for group in "Breaking changes:$breaking" "Features:$features" "Fixes:$fixes" "Performance:$performance"; do
    if [ -n "${group#*:}" ]; then printf '\n### %s\n\n%s' "${group%%:*}" "${group#*:}"; fi
  done
}

# The newest tag reachable from $1 that a release of $2 counts from: any v* tag for a pre-release, the
# newest stable one for a release. Empty when there's none (the first release).
previous_tag() {
  local exclude=()
  if [[ "$2" != *-* ]]; then exclude=(--exclude 'v*-*'); fi
  git describe --tags --abbrev=0 --match 'v[0-9]*' ${exclude[@]+"${exclude[@]}"} "$1" 2>/dev/null || true
}

[ $# -ge 2 ] || usage
command="$1" version="${2#v}"
case "$command" in
  section)
    if [ $# -eq 4 ]; then
      section "$version" "$3" "$4" "$(git log -1 --format=%cs "$4")"
    elif [ $# -eq 2 ]; then
      section "$version" "$(previous_tag HEAD "$version")" HEAD "$(date +%F)"
    else
      usage
    fi
    ;;
  add)
    [ $# -eq 2 ] || usage
    if [ -f "$CHANGELOG" ] && grep -q "^## $version (" "$CHANGELOG"; then fail "$CHANGELOG already has $version"; fi
    new="$(section "$version" "$(previous_tag HEAD "$version")" HEAD "$(date +%F)")"
    old=""
    if [ -f "$CHANGELOG" ]; then old="$(awk '/^## /{found=1} found' "$CHANGELOG")"; fi
    printf '%s\n\n%s\n%s' "$HEADER" "$new" "${old:+$'\n'$old$'\n'}" > "$CHANGELOG"
    echo "✓ $CHANGELOG: added $version"
    ;;
  notes)
    [ $# -eq 2 ] || usage
    [ -f "$CHANGELOG" ] || fail "no $CHANGELOG"
    grep -q "^## $version (" "$CHANGELOG" || fail "$CHANGELOG has no section for $version"
    notes="$(awk -v heading="## $version (" '
      index($0, heading) == 1 { found = 1; next }
      found && /^## / { exit }
      found { print }
    ' "$CHANGELOG" | sed -e '/./,$!d')"
    printf '%s\n' "$notes"
    ;;
  *) usage ;;
esac
