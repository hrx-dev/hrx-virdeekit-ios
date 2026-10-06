//
// VirdeeService.swift
// VirdeeKit
//
// Created by Oleksandr Malinchuk on 31.07.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import UIKit
import Combine

// MARK: - Session

public enum VirdeeEnvironment: String {
    case development
    case staging
    case production
}

/// Credentials for one guest and one reservation. The HRX backend issues these —
/// Virdee forbid requesting them from the client, because the tenant-level API key
/// used to mint them would grant access to every reservation, not just this one.
public struct VirdeeSession {
    public let accessGrantId: String
    public let accessToken: String
    public let environment: VirdeeEnvironment

    public init(accessGrantId: String, accessToken: String, environment: VirdeeEnvironment) {
        self.accessGrantId = accessGrantId
        self.accessToken = accessToken
        self.environment = environment
    }
}

// MARK: - Requirements

/// One prerequisite the guest must satisfy before check-in completes,
/// as reported by the access grant.
public struct VirdeeRequirement: Equatable {
    public let type: String
    public let status: String

    public var isComplete: Bool { status == "COMPLETED" }

    /// `ID_VERIFICATION` -> `Id Verification`
    public var displayName: String {
        type.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Events

/// What happened inside a presented flow.
public enum VirdeeFlowOutcome: Equatable {
    case succeeded
    case cancelled
    case closed
    /// `code` comes from the SDK — e.g. `CLEAR_USER_CANCELLED`,
    /// `VERIFICATION_REJECTED`, `MISSING_ACCESS_GRANT` — and is the value to
    /// branch on. `message` is for humans and is not stable.
    case failed(code: String, message: String)
    case progress(String)
}

public enum VirdeeEvent {
    /// The hidden controller finished reading the access grant.
    case requirementsLoaded([VirdeeRequirement])
    /// ID verification is outstanding — show your own CTA, then call `presentIDVerification()`.
    case idVerificationRequired
    /// The digital key can be opened. Independent of requirements.
    case mobileKeyAvailable
    case idVerification(VirdeeFlowOutcome)
    case mobileKey(VirdeeFlowOutcome)
    /// The SDK could not start (bad credentials, no network, expired grant).
    case failedToStart(message: String)

    /// CLEAR ID verification is off screen and nothing further will arrive for it.
    ///
    /// Sent *after* the overlay window is hidden and released, so by the time the host
    /// sees this the surface is gone. Always preceded by an `.idVerification(_)` outcome
    /// describing *how* it ended; this one only says the screen is down.
    ///
    /// Not sent when the host calls `stop()` — the host initiated that and already knows.
    case idVerificationDismissed

    /// The digital key screen is off screen and nothing further will arrive for it.
    ///
    /// Same guarantees as `idVerificationDismissed`. This is the only signal the host
    /// gets that the mobile key flow is over: unlike ID verification, which is followed
    /// by `.mobileKeyAvailable`, nothing else marks the end of it.
    case mobileKeyDismissed
}

// MARK: - Service

/// The entire surface HRX sees. Nothing React Native leaks past this protocol —
/// no RCTRootView, no bridge, no module names.
///
/// Presentation is owned by VirdeeKit rather than handed back as a `UIViewController`
/// on purpose: the SDK's screens are mounted into a transparent key `UIWindow`, which
/// is what lets `react-native-screens` present its own modals correctly.
public protocol VirdeeService: AnyObject {

    var events: AnyPublisher<VirdeeEvent, Never> { get }

    /// Console verbosity. Settable at any time, including mid-session — useful
    /// for turning `.debug` on from a hidden developer menu without a rebuild.
    var logLevel: VirdeeLogLevel { get set }

    /// Latest requirements reported by the SDK, or empty before `start`.
    var requirements: [VirdeeRequirement] { get }

    /// Boots the React Native runtime and the SDK for one reservation.
    /// Cheap to call again for the same session — the hidden surface is re-armed
    /// rather than rebuilt.
    func start(session: VirdeeSession)

    /// Re-reads requirements for the session already started.
    func refresh()

    /// Presents CLEAR ID verification full-screen. Call after `.idVerificationRequired`.
    func presentIDVerification()

    /// Presents the digital key screen. Call after `.mobileKeyAvailable`.
    func presentMobileKey()

    /// Ends the session: detaches the bridge and unmounts every Virdee surface.
    ///
    /// **The JS runtime is deliberately kept alive** for the lifetime of the process.
    /// Virdee confirmed the SDK is meant to live that long, and tearing React Native
    /// down and building it again crashed in production — see CHANGELOG 0.6.0. A later
    /// `start(session:)` reuses the warm runtime, which also makes it faster.
    ///
    /// **Safe to call from inside an `events` handler**, including the handler for the
    /// event that ended the flow. Idempotent: calling it twice, or without a preceding
    /// `start(session:)`, does nothing.
    ///
    /// No `events` are published as a result of this call.
    func stop()
}
