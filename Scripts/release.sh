#!/usr/bin/env bash
#
# Cuts a VirdeeKit release: verifies the committed binary is current, then tags
# and (with --push) publishes.
#
#   bash Scripts/release.sh 0.3.0
#   bash Scripts/release.sh 0.3.0 --push
#
# SwiftPM versions ARE git tags — Package.swift carries no version field.
#
# The failure this guards against: the .xcframework is committed, so a tag can
# silently point at a binary built before the last source change. The diff looks
# innocent and the team gets code that was never built.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
PUSH="${2:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: bash Scripts/release.sh <major.minor.patch> [--push]" >&2
  exit 1
fi

FRAMEWORK="Artifacts/VirdeeKit.xcframework"
VERSION_FILE="Example/ios/VirdeeKit/VirdeeKitVersion.swift"

# --- 1. the artifact must exist and be committed -----------------------------
[ -d "$FRAMEWORK" ] || { echo "error: $FRAMEWORK missing — run Scripts/build-xcframework.sh" >&2; exit 1; }

if [ -n "$(git status --porcelain -- "$FRAMEWORK")" ]; then
  echo "error: $FRAMEWORK has uncommitted changes. Commit the rebuilt binary first." >&2
  exit 1
fi

# --- 2. no build-machine paths inside the shipped binary ---------------------
# folly and React-Fabric bake __FILE__ into assertion strings; without
# -ffile-prefix-map the artifact leaks whoever built it. See the README.
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
  binary="$FRAMEWORK/$slice/VirdeeKit.framework/VirdeeKit"
  [ -f "$binary" ] || continue
  leaked=$(strings "$binary" | grep -c "/Users/\|/private/tmp" || true)
  if [ "$leaked" -ne 0 ]; then
    echo "error: $slice contains $leaked absolute build paths." >&2
    echo "       Check -ffile-prefix-map in the Podfile and on the VirdeeKit target." >&2
    exit 1
  fi
done

# --- 3. the artifact must be newer than the sources that produce it ----------
# Commit times, not mtimes: mtimes do not survive a fresh clone.
artifact_commit=$(git log -1 --format=%ct -- "$FRAMEWORK")
sources_commit=$(git log -1 --format=%ct -- Example/ios/VirdeeKit Example/index.js Example/package.json Example/yarn.lock)

if [ -n "$sources_commit" ] && [ -n "$artifact_commit" ] && [ "$sources_commit" -gt "$artifact_commit" ]; then
  echo "error: Example sources changed after $FRAMEWORK was last committed." >&2
  echo "       The tag would point at a stale binary. Rebuild:" >&2
  echo "         bash Scripts/build-xcframework.sh && git add $FRAMEWORK && git commit" >&2
  exit 1
fi

# --- 4. the version stamp inside the binary must match the tag ---------------
stamped=$(sed -n 's/.*let version = "\(.*\)".*/\1/p' "$VERSION_FILE")
if [ "$stamped" != "$VERSION" ]; then
  echo "error: $VERSION_FILE says $stamped but you are tagging $VERSION." >&2
  echo "       Update it, rebuild, commit, then re-run:" >&2
  echo "         sed -i '' 's/let version = \"$stamped\"/let version = \"$VERSION\"/' $VERSION_FILE" >&2
  echo "         bash Scripts/build-xcframework.sh" >&2
  exit 1
fi

# --- 5. a consumer can actually build against the manifest -------------------
# 0.3.0 shipped a Package.swift that no consumer could compile. Nothing caught it,
# because every other check builds Example/, which never goes through Package.swift.
echo "==> Verifying the package from a consumer's point of view"
bash "$ROOT/Scripts/verify-package.sh" >/dev/null || {
  echo "error: a consumer cannot build against this package." >&2
  echo "       Run: bash Scripts/verify-package.sh" >&2
  exit 1
}

# --- 6. nothing else outstanding, and the tag is free ------------------------
[ -z "$(git status --porcelain)" ] || { echo "error: working tree is dirty" >&2; git status --short >&2; exit 1; }

if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "error: tag $VERSION already exists" >&2
  exit 1
fi

# --- 6. tag ------------------------------------------------------------------
sdk=$(sed -n 's/.*let sdkCore = "\(.*\)".*/\1/p' "$VERSION_FILE")
git tag -a "$VERSION" -m "VirdeeKit $VERSION (sdk-core $sdk)"
echo "tagged $VERSION"

if [ "$PUSH" = "--push" ]; then
  git push origin "$VERSION"
  echo "pushed $VERSION"
else
  echo
  echo "Not pushed. Publish with:"
  echo "  git push origin $VERSION"
fi

cat <<EOF

In HRX, set the dependency rule to "Up to Next Major" from $VERSION.
Patches and minors then arrive on their own; a major stays a deliberate decision.
EOF
