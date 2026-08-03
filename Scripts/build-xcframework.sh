#!/usr/bin/env bash
#
# Builds Artifacts/VirdeeKit.xcframework (device + simulator) from Example/.
#
# Prerequisites:
#   cd Example && yarn install && cd ..
#   cd Example/ios && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 RCT_NEW_ARCH_ENABLED=1 pod install
#
# The npm token for the private @virdee-inc scope lives in ~/.yarnrc.yml, never here.
#
# A cold build compiles React Native from source: expect well over an hour per slice.
# Later runs reuse .build/DerivedData.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/Example"
IOS="$EXAMPLE/ios"
BUILD="$ROOT/.build"
OUT="$ROOT/Artifacts"
WORKSPACE="$IOS/VirdeeNativeSDKExample.xcworkspace"

if [ ! -d "$IOS/Pods" ]; then
  echo "error: $IOS/Pods missing — run pod install first (see header)" >&2
  exit 1
fi

rm -rf "$OUT/VirdeeKit.xcframework" "$BUILD/device.xcarchive" "$BUILD/simulator.xcarchive"
mkdir -p "$BUILD" "$OUT"

echo "==> Bundling JS"
rm -rf "$BUILD/jsbundle"
mkdir -p "$BUILD/jsbundle"
( cd "$EXAMPLE" && yarn react-native bundle \
    --platform ios \
    --dev false \
    --entry-file index.js \
    --bundle-output "$BUILD/jsbundle/main.jsbundle" \
    --assets-dest "$BUILD/jsbundle" )

archive() {
  local destination="$1" name="$2"
  echo "==> Archiving $name"
  # Two settings deliberately NOT passed here:
  #
  #   BUILD_LIBRARY_FOR_DISTRIBUTION=YES — command-line settings override every
  #   target, including all 82 pods, and NitroModules (a SEOS dependency) cannot
  #   emit a .swiftinterface because of its C++ interop `margelo` namespace:
  #     error: no type named 'margelo' in module 'NitroModules'
  #   It is set on the VirdeeKit target itself instead, and forced off for pods
  #   in the Podfile's post_install.
  #
  # Signing is configured on the target (unsigned), not here. A distributable
  # xcframework ships unsigned and is signed by whoever embeds it; ad-hoc is
  # rejected outright by the device SDK ("Ad Hoc code signing is not allowed").
  # Note the app that embeds it MUST sign normally, or the SEOS plugin's vendored
  # dynamic framework aborts at launch with "Library not loaded".
  xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme VirdeeKit \
    -configuration Release \
    -destination "$destination" \
    -archivePath "$BUILD/$name.xcarchive" \
    -derivedDataPath "$BUILD/DerivedData" \
    SKIP_INSTALL=NO \
    > "$BUILD/$name.log" 2>&1 \
    || { echo "error: $name archive failed — see $BUILD/$name.log" >&2; exit 1; }

  local fw="$BUILD/$name.xcarchive/Products/Library/Frameworks/VirdeeKit.framework"
  [ -d "$fw" ] || { echo "error: no framework in $name archive — see $BUILD/$name.log" >&2; exit 1; }
}

archive "generic/platform=iOS"           "device"
archive "generic/platform=iOS Simulator" "simulator"

# VirdeeRuntime resolves the release bundle against the framework bundle, not
# Bundle.main, so it has to live inside each slice.
for slice in device simulator; do
  cp -R "$BUILD/jsbundle/." \
    "$BUILD/$slice.xcarchive/Products/Library/Frameworks/VirdeeKit.framework/"
done

# .abi.json is compiler diagnostic metadata, not needed to consume the framework,
# and it embeds absolute build paths. Drop it rather than ship the build machine's
# directory layout (and whoever's home directory) inside a committed artifact.
find "$BUILD"/*.xcarchive -name "*.abi.json" -delete 2>/dev/null || true

echo "==> Creating xcframework"
xcodebuild -create-xcframework \
  -framework "$BUILD/device.xcarchive/Products/Library/Frameworks/VirdeeKit.framework" \
  -framework "$BUILD/simulator.xcarchive/Products/Library/Frameworks/VirdeeKit.framework" \
  -output "$OUT/VirdeeKit.xcframework"

echo
du -sh "$OUT/VirdeeKit.xcframework"
echo "Commit it and tag a version — SwiftPM versions are git tags."
