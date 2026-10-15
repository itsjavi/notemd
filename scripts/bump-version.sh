#!/usr/bin/env bash
# Bumps VERSION, commits it and tags the commit vX.Y.Z (the tag release.yml builds).
#
#   scripts/bump-version.sh <major|minor|patch|X.Y.Z|X.Y.Z-beta.N> [--push]
#
#   --push   pushes main and the tag together, which starts the Release workflow (it builds,
#            signs and publishes; nothing is built locally)
#   X.Y.Z-beta.N publishes a GitHub pre-release; after one, name the next version (not major|minor|patch)
#
# X.Y.Z equal to VERSION tags the current commit without a bump (a first release, or a version nothing tagged yet).
# Needs a clean working tree on main, so the tagged commit is exactly what gets released.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '4,8s/^# \{0,1\}//p' "$0" >&2; exit 64; }
fail() { echo "✗ $*" >&2; exit 1; }

target="" push=0
for arg in "$@"; do
  case "$arg" in
    --push) push=1 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option $arg" >&2; usage ;;
    *) [ -z "$target" ] || usage; target="$arg" ;;
  esac
done
[ -n "$target" ] || usage

semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$'
current="$(tr -d '[:space:]' < VERSION)"
[[ "$current" =~ $semver ]] || fail "VERSION holds “${current}”, not X.Y.Z or X.Y.Z-<pre-release>"
major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}" pre="${BASH_REMATCH[4]}"

case "$target" in
  major|minor|patch) [ -z "$pre" ] || fail "VERSION is the pre-release $current; name the next version" ;;
esac
case "$target" in
  major) next="$((major + 1)).0.0" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  patch) next="$major.$minor.$((patch + 1))" ;;
  *)
    next="${target#v}"
    [[ "$next" =~ $semver ]] || fail "“${target}” isn't major, minor, patch, X.Y.Z or X.Y.Z-<pre-release>"
    ;;
esac

# Whether $1 comes after $2 in semver order: X.Y.Z numerically, then a pre-release before its release
# (2.1.0-beta.2 < 2.1.0), and pre-releases of one version by sort -V (beta.2 < beta.10 < rc.1).
newer() {
  local a="${1%%-*}" b="${2%%-*}"
  if [ "$a" != "$b" ]; then
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$a" ]
    return
  fi
  local a_pre="${1#"$a"}" b_pre="${2#"$b"}"
  [ "$a_pre" != "$b_pre" ] || return 1
  [ -n "$a_pre" ] || return 0
  [ -n "$b_pre" ] || return 1
  [ "$(printf '%s\n%s\n' "$a_pre" "$b_pre" | sort -V | tail -1)" = "$a_pre" ]
}

# The new version must be higher: Sparkle and the website pick the newest by version. The current one can be tagged
# as it is when no tag has it yet (the tag check below).
retag=0
if [ "$next" = "$current" ]; then
  retag=1
else
  newer "$next" "$current" || fail "$next isn't higher than the current $current"
fi

tag="v$next"
[ "$(git branch --show-current)" = main ] || fail "check out main first (releases are tagged on main)"
[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first; the tag must match what gets built"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "tag $tag already exists"

if [ "$push" = 1 ]; then
  git fetch -q origin main --tags
  git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null && fail "tag $tag already exists on origin"
  [ -z "$(git rev-list HEAD..origin/main)" ] || fail "main is behind origin/main; pull first"
fi

if [ "$retag" = 1 ]; then
  git tag -a "$tag" -m "NoteMD $next"
  echo "✓ Tagged $tag on the current commit (VERSION is already $next)"
else
  echo "$next" > VERSION
  git add VERSION
  git commit -q -m "chore(release): $tag"
  git tag -a "$tag" -m "NoteMD $next"
  echo "✓ $current → $next, committed and tagged $tag"
fi

if [ "$push" = 1 ]; then
  # Both or neither: a pushed tag without its commit on main (or the reverse) confuses releases.
  git push -q --atomic origin HEAD:main "refs/tags/$tag"
  echo "✓ Pushed main and $tag: the Release workflow is building it"
else
  echo "  Push when ready: git push --atomic origin main $tag"
fi
