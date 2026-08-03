#!/usr/bin/env bash
#
# Gets a machine ready to build VirdeeKit, then optionally builds it.
#
#   bash Scripts/bootstrap.sh           # check prerequisites + install dependencies
#   bash Scripts/bootstrap.sh --build   # ... and then build the xcframework
#   bash Scripts/bootstrap.sh --check   # preflight only, change nothing
#
# Every check below exists because it actually went wrong once. The build takes
# hours, so anything that can fail is checked up front rather than at minute 150.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/Example"
MODE="${1:-}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

FAILED=0
fail() { bad "$1"; shift; for line in "$@"; do note "$line"; done; FAILED=1; }

# --- preflight ---------------------------------------------------------------
bold "Checking prerequisites"

# Xcode. Any recent version works — the framework is built with library evolution
# so it stays consumable across Xcode versions.
if xcodebuild -version >/dev/null 2>&1; then
  ok "Xcode $(xcodebuild -version | head -1 | awk '{print $2}')"
else
  fail "Xcode command line tools not usable" \
       "Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
fi

# Node 18+.
if command -v node >/dev/null 2>&1; then
  node_major=$(node -p "process.versions.node.split('.')[0]")
  if [ "$node_major" -ge 18 ]; then
    ok "Node $(node -v)"
  else
    fail "Node $(node -v) is too old (need >= 18)"
  fi
else
  fail "Node not found" "Install Node 18+ (nvm, mise or brew)"
fi

# Yarn 4. package.json pins it via packageManager, but corepack has to be on or
# the shell resolves the classic 1.x, which cannot read this Berry lockfile.
if command -v corepack >/dev/null 2>&1; then
  corepack enable >/dev/null 2>&1
  yarn_version=$( cd "$EXAMPLE" && yarn --version 2>/dev/null )
  case "$yarn_version" in
    4.*) ok "Yarn $yarn_version" ;;
    "")  fail "Yarn not resolvable in Example/" "Run: corepack enable" ;;
    *)   fail "Yarn $yarn_version resolved, need 4.x" \
              "The lockfile is Berry format; classic yarn cannot read it." \
              "Run: corepack enable && corepack prepare yarn@4.5.3 --activate" ;;
  esac
else
  fail "corepack not found" "Ships with Node 16.9+; reinstall Node"
fi

# CocoaPods.
if command -v pod >/dev/null 2>&1 && pod --version >/dev/null 2>&1; then
  ok "CocoaPods $(pod --version 2>/dev/null | tail -1)"
else
  fail "CocoaPods not usable" "Install: sudo gem install cocoapods"
fi

# The npm token for the private @virdee-inc scope. Checked by using it, never by
# reading it — this script must not see or print the value.
if [ -f "$HOME/.yarnrc.yml" ] && grep -q "npmAuthToken" "$HOME/.yarnrc.yml" 2>/dev/null; then
  if ( cd "$EXAMPLE" && yarn npm info @virdee-inc/sdk-core --json >/dev/null 2>&1 ); then
    ok "@virdee-inc registry access"
  else
    fail "Token in ~/.yarnrc.yml is present but rejected" \
         "It may be expired or lack access. Ask for a new one and replace" \
         "the npmAuthToken line in ~/.yarnrc.yml."
  fi
else
  fail "No npm token for the private @virdee-inc scope" \
       "Create ~/.yarnrc.yml (chmod 600) containing:" \
       "" \
       "  nodeLinker: node-modules" \
       "  npmScopes:" \
       "    virdee-inc:" \
       "      npmRegistryServer: \"https://registry.npmjs.org\"" \
       "      npmAuthToken: \"<your token>\"" \
       "" \
       "Yarn Berry does NOT read ~/.npmrc, so it must be configured here." \
       "Use a text editor, not echo — the shell would log the token to history."
fi

# Disk. A cold build produces several GB of DerivedData; running out at minute
# 150 is the worst way to learn this.
avail_gb=$(df -g "$ROOT" 2>/dev/null | tail -1 | awk '{print $4}')
if [ -n "${avail_gb:-}" ] && [ "$avail_gb" -ge 25 ]; then
  ok "Disk ${avail_gb}G free"
elif [ -n "${avail_gb:-}" ]; then
  fail "Only ${avail_gb}G free — a cold build needs roughly 25G" \
       "Free some space, or delete .build/DerivedData from a previous run."
fi

# Not under /tmp. macOS periodically deletes files there that have not been
# accessed recently — mid-project it silently ate the git directory, several
# scripts and the whole CocoaPods support-file tree.
case "$ROOT" in
  /tmp/*|/private/tmp/*)
    fail "This checkout lives under /tmp" \
         "macOS prunes /tmp on a schedule and will corrupt the working tree." \
         "Move it somewhere permanent, e.g. ~/Documents/Projects/." ;;
  *) ok "Checkout is outside /tmp" ;;
esac

echo
if [ "$FAILED" -ne 0 ]; then
  bold "Preflight failed — fix the above and re-run."
  exit 1
fi
bold "Preflight passed."

[ "$MODE" = "--check" ] && exit 0

# --- dependencies ------------------------------------------------------------
set -e
echo
bold "Installing JS dependencies"
( cd "$EXAMPLE" && yarn install )

echo
bold "Installing pods"
# LANG/LC_ALL are required on the macOS system Ruby 2.6, which otherwise dies with
# "Unicode Normalization not appropriate for ASCII-8BIT" before doing any work.
( cd "$EXAMPLE/ios" && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 RCT_NEW_ARCH_ENABLED=1 pod install )

echo
bold "Ready."

if [ "$MODE" != "--build" ]; then
  echo "Build the framework with:"
  echo "  bash Scripts/build-xcframework.sh"
  echo
  echo "Or open Example/ios/VirdeeNativeSDKExample.xcworkspace to work on the"
  echo "Virdee screens with Metro (yarn start) instead."
  exit 0
fi

# --- build -------------------------------------------------------------------
echo
bold "Building the xcframework — this takes hours on a cold cache"
started=$(date +%s)
bash "$ROOT/Scripts/build-xcframework.sh"
elapsed=$(( $(date +%s) - started ))
printf '\nBuild took %dh %dm\n' $(( elapsed / 3600 )) $(( (elapsed % 3600) / 60 ))
