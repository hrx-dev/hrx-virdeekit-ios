//
// VirdeeCredentials.swift
// VirdeeNativeSDKExample
//
// Created by Oleksandr Malinchuk on 31.07.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import Foundation
import VirdeeKit

/// Test credentials for the harness.
///
/// These are per-guest, per-reservation and short-lived; in HRX they come from
/// the backend at runtime and are never compiled in. Hard-coding them is fine
/// here and only here.
///
/// Ask Virdee for a development access grant. `accessToken` is issued for one
/// environment — a development token will not work against production.
enum VirdeeCredentials {
    static let accessGrantId = "YOUR_ACCESS_GRANT_ID"
    static let accessToken = "YOUR_ACCESS_TOKEN"
    static let environment: VirdeeEnvironment = .development

    static var isConfigured: Bool {
        !accessGrantId.hasPrefix("YOUR_") && !accessToken.hasPrefix("YOUR_")
    }

    static var session: VirdeeSession {
        VirdeeSession(
            accessGrantId: accessGrantId,
            accessToken: accessToken,
            environment: environment
        )
    }
}
