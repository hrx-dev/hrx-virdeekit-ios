#!/usr/bin/env bash
#
# Compiles a throwaway consumer against the package, the way HRX consumes it.
#
#   bash Scripts/verify-package.sh
#
# Everything else in this repo tests the framework by building Example/, which
# compiles VirdeeKit from source and never goes through Package.swift at all. So a
# manifest can be wrong in ways nothing catches: the wrapper target shipped in 0.3.0
# did `@_exported import VirdeeKitBinary`, but a binaryTarget's name is only a SwiftPM
# label — the module name comes from the framework inside the xcframework, which is
# `VirdeeKit`. Every consumer got "Cannot find 'VirdeeConfiguration' in scope" while
# the harness kept building green.
#
# This is the only check that fails on that class of mistake.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DEST="${DEST:-generic/platform=iOS Simulator}"

mkdir -p "$WORK/Consumer/Sources/Consumer"

cat > "$WORK/Consumer/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Consumer", targets: ["Consumer"])],
    dependencies: [.package(path: "$ROOT")],
    targets: [
        .target(name: "Consumer",
                dependencies: [.product(name: "VirdeeKit", package: "virdee-ios-kit")])
    ]
)
EOF

# Touch every public type. A consumer that only imports the module would still
# compile if the module were empty.
cat > "$WORK/Consumer/Sources/Consumer/Consumer.swift" <<'EOF'
import Combine
import VirdeeKit

enum Consumer {
    static func exercisePublicAPI() -> AnyPublisher<VirdeeEvent, Never> {
        let service: VirdeeService = VirdeeServiceImpl(
            configuration: VirdeeConfiguration(logLevel: .error) { (entry: VirdeeLogEntry) in
                _ = (entry.level, entry.category, entry.message, entry.date)
            }
        )

        service.logLevel = .debug
        service.start(session: VirdeeSession(
            accessGrantId: "",
            accessToken: "",
            environment: .production
        ))
        service.refresh()
        service.presentIDVerification()
        service.presentMobileKey()
        service.stop()

        _ = service.requirements.map { (r: VirdeeRequirement) in (r.type, r.status, r.isComplete, r.displayName) }
        _ = VirdeeKitVersion.version
        _ = VirdeeFlowOutcome.failed(code: "", message: "")

        return service.events
    }
}
EOF

echo "==> Building a consumer against $ROOT"
cd "$WORK/Consumer"

if xcodebuild -scheme Consumer -destination "$DEST" build 2>&1 | tee "$WORK/build.log" | grep -qE "^\*\* BUILD SUCCEEDED"; then
  echo
  echo "OK — 'import VirdeeKit' resolves and the public API is reachable."
else
  echo
  echo "error: a consumer cannot build against this package." >&2
  grep -E "error:" "$WORK/build.log" | sort -u | head -20 >&2
  exit 1
fi
