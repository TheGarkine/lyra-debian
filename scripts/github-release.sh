#!/usr/bin/env bash
# Publish a GitHub release from the TOP section of RELEASE_NOTES.md.
#
# Workflow: add a new section at the top of RELEASE_NOTES.md (heading must
# contain the version, e.g. "# v0.2.0 — ..."), separated from older notes by a
# line of dashes (-----). Then run:  make github-release
#
# The script extracts that top section, uses its version as the git tag, runs
# `make release` to collect artifacts, tags, pushes, and creates the GitHub
# release with ONLY the top section as its notes.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "ERROR: $*" >&2; exit 1; }

command -v gh >/dev/null || die "GitHub CLI (gh) not installed — brew install gh && gh auth login"
[ -f RELEASE_NOTES.md ] || die "RELEASE_NOTES.md not found"

# Top section = everything above the first ----- separator line.
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
awk '/^-----/{exit} {print}' RELEASE_NOTES.md > "$NOTES"
[ -s "$NOTES" ] || die "RELEASE_NOTES.md top section is empty"

VERSION="$(head -n1 "$NOTES" | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)" \
    || die "no version (vX.Y[.Z]) found in the first heading of RELEASE_NOTES.md"
TITLE="$(head -n1 "$NOTES" | sed 's/^#* *//')"

echo "Releasing $VERSION — \"$TITLE\""
echo "--- notes: ---------------------------------------------"
cat "$NOTES"
echo "--------------------------------------------------------"

git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1 && die "tag $VERSION already exists"
gh release view "$VERSION" >/dev/null 2>&1 && die "GitHub release $VERSION already exists"

if [ -n "$(git status --porcelain)" ]; then
    git status --short
    die "working tree is dirty — commit first"
fi

echo "Collecting artifacts (make release)..."
make release

printf "Tag, push and publish release %s? Type yes to continue: " "$VERSION"
read -r a; [ "$a" = yes ] || die "aborted"

git tag -a "$VERSION" -m "$TITLE"
git push origin HEAD --tags
gh release create "$VERSION" out/release/* --title "$TITLE" --notes-file "$NOTES"

echo "Done: $(gh release view "$VERSION" --json url -q .url)"
