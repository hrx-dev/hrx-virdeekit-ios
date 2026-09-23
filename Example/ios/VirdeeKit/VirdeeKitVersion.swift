//
// VirdeeKitVersion.swift
// VirdeeKit
//
// Created by Oleksandr Malinchuk on 31.07.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import Foundation

/// Identifies the binary actually inside a build. `Package.resolved` records which
/// version SwiftPM *resolved*, which is not the same thing once someone has been
/// testing a branch — ask the framework itself instead.
///
/// Scripts/release.sh rewrites these; do not edit by hand.
public enum VirdeeKitVersion {

    /// VirdeeKit's own semver — the version of the `VirdeeService` contract,
    /// not of the Virdee SDK inside it.
    public static let version = "0.4.0"

    /// The `@virdee-inc/sdk-core` release this binary was built against.
    public static let sdkCore = "4.2.0"

    /// Vendor plugins compiled in.
    public static let plugins = [
        "sdk-mobile-key-seos": "1.1.1",
        "sdk-idv-clear": "1.2.0",
    ]

    /// One line for logs and bug reports.
    public static var summary: String {
        let pluginList = plugins.map { "\($0.key)@\($0.value)" }.sorted().joined(separator: ", ")
        return "VirdeeKit \(version) (sdk-core \(sdkCore); \(pluginList))"
    }
}
