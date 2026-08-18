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
// All three go in the product so the consumer links and embeds them by adding one
// library. `import VirdeeKit` still resolves to a single module: SEOS and hermes
// expose no Swift interface of their own.
//
// There is deliberately no wrapper target re-exporting the binary. A binaryTarget's
// name here is only a SwiftPM label — the importable module name comes from the
// framework inside the xcframework, which is `VirdeeKit`. A wrapper would both
// collide with that name and be unable to import it.
let package = Package(
    name: "VirdeeKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(
            name: "VirdeeKit",
            targets: ["VirdeeKit", "SeosMobileKeysSDK", "hermes"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "VirdeeKit",
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
        )
    ]
)
