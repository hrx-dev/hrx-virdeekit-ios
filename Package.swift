// swift-tools-version: 5.9
import PackageDescription

// VirdeeKit ships as a prebuilt binary. SwiftPM cannot build React Native (its build
// is driven by CocoaPods podspecs and codegen scripts), and putting a Podfile on the
// host app would drag the whole project into an .xcworkspace and make every developer
// compile React Native from source on first clone.
//
// The framework is dynamic, so -ObjC and -force_load are resolved while building it
// and consumers need no unsafeFlags — which SwiftPM forbids for versioned dependencies
// anyway.
//
// NOTE: this declares one binary target, but VirdeeKit links two more dynamic
// frameworks it does not contain — SeosMobileKeysSDK and hermes. Until those ship here
// as binary targets too, a consumer aborts at launch with "Library not loaded".
// See "VirdeeKit is three binaries, not one" in the README.
let package = Package(
    name: "VirdeeKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VirdeeKit", targets: ["VirdeeKit"])
    ],
    targets: [
        .binaryTarget(
            name: "VirdeeKitBinary",
            path: "Artifacts/VirdeeKit.xcframework"
        ),
        .target(
            name: "VirdeeKit",
            dependencies: ["VirdeeKitBinary"],
            path: "Sources/VirdeeKit",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AuthenticationServices")
            ]
        )
    ]
)
