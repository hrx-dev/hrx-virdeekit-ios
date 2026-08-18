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
/// `accessToken` is issued for exactly one environment, and `environment` below
/// must match the one that issued it. A mismatch is not reported as an auth
/// error: the server fails during GraphQL context creation and returns
///
///     HTTP 500  Context creation failed: Unauthorized
///
/// which reads like an outage. To tell the two apart, POST any query to the
/// environment's backend with the token, then again with the last character of
/// the signature changed. Identical responses mean the token is not one this
/// environment can verify — try another environment before suspecting the token.
enum VirdeeCredentials {
    static let accessGrantId = "YOUR_ACCESS_GRANT_ID"
    static let accessToken = "YOUR_ACCESS_TOKEN"
    static let environment: VirdeeEnvironment = .production

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
