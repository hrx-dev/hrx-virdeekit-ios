// swift-tools-version: 5.9
import PackageDescription

// VirdeeKit ships as a prebuilt binary. SwiftPM cannot build React Native (its build
// is driven by CocoaPods podspecs and codegen scripts), and putting a Podfile on the
// host app would drag the whole project into an .xcworkspace and make every developer
// compile React Native from source on first clone.
//
// Three binary targets, not one. VirdeeKit.framework links two vendored dynamic
// frameworks that it does not contain:
//
//   otool -L Artifacts/VirdeeKit.xcframework/ios-arm64/VirdeeKit.framework/VirdeeKit
//     @rpath/SeosMobileKeysSDK.framework/SeosMobileKeysSDK
//     @rpath/hermes.framework/hermes
//
// They have to ship alongside or the app aborts the moment it launches with
// "Library not loaded". Building and linking succeed either way — this only shows
// at runtime, which is why it went unnoticed for a while.
//
// The consumer still imports one module: the wrapper target re-exports the binary
// and carries the linker settings a binaryTarget cannot.
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
        // ASSA ABLOY SEOS, vendored by @virdee-inc/sdk-mobile-key-seos.
        .binaryTarget(
            name: "SeosMobileKeysSDK",
            path: "Artifacts/SeosMobileKeysSDK.xcframework"
        ),
        // Hermes, the JS engine React Native runs on. Trimmed to the two iOS
        // slices; the copy CocoaPods vendors also carries tvOS, Mac Catalyst and
        // visionOS, which more than triples its size for nothing.
        .binaryTarget(
            name: "hermes",
            path: "Artifacts/hermes.xcframework"
        ),
        .target(
            name: "VirdeeKit",
            dependencies: [
                "VirdeeKitBinary",
                "SeosMobileKeysSDK",
                "hermes"
            ],
            path: "Sources/VirdeeKit",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AuthenticationServices")
            ]
        )
    ]
)
