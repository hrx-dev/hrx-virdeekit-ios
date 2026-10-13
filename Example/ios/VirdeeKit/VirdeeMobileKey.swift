//
// VirdeeMobileKey.swift
// VirdeeKit
//
// Created by Oleksandr Malinchuk on 12.10.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import Combine
import Foundation

// MARK: - State

/// Where the key is in its lifecycle. Mirrors `MobileKeyStatus` in the SEOS plugin.
public enum VirdeeMobileKeyPhase: String, Equatable, Sendable {
    case idle
    /// Checking access and permissions.
    case initializing
    /// Retrieving or creating the key — the long one, worth a progress indicator.
    case provisioningKey
    /// The key is on the device; `openLock()` will start scanning.
    case ready
    /// BLE scanning. "Hold your phone near the reader".
    case unlocking
    case success
    case error
}

/// Why Bluetooth is unusable, when it is.
///
/// Separate from `errorMessage` because the design treats these as distinct screens:
/// "Bluetooth is Off" has no button, while a denied permission offers Open Settings
/// (`UIApplication.openSettingsURLString` — the host opens it; VirdeeKit does not).
public enum VirdeeBluetoothIssue: String, Equatable, Sendable {
    /// `BLE_OFF` — the radio is off. Nothing to tap; iOS has no toggle URL.
    case off
    /// `BLE_PERMISSION_DENIED` / `BLE_UNAUTHORIZED` — send the guest to Settings.
    case permissionDenied
    /// `BLE_NOT_SUPPORTED`
    case unsupported
    /// `BLE_RESETTING` — transient, the radio is restarting.
    case resetting
    /// `BLE_CONNECTION_LOST` / `BLE_FAILURE` — reached the lock and failed.
    case communicationFailed

    init?(code: String?) {
        switch code {
        case "BLE_OFF":                             self = .off
        case "BLE_PERMISSION_DENIED", "BLE_UNAUTHORIZED": self = .permissionDenied
        case "BLE_NOT_SUPPORTED":                   self = .unsupported
        case "BLE_RESETTING":                       self = .resetting
        case "BLE_CONNECTION_LOST", "BLE_FAILURE":  self = .communicationFailed
        default:                                    return nil
        }
    }
}

/// Everything a custom key screen needs. Published on the main queue.
public struct VirdeeMobileKeyState: Equatable, Sendable {

    public let phase: VirdeeMobileKeyPhase
    /// The SDK is re-syncing the endpoint behind the scenes. Usually worth a
    /// "just a moment" rather than an error, even though it follows a failure.
    public let isRecovering: Bool

    /// Set only when the failure is a Bluetooth one. Check this before
    /// `errorMessage`: these cases have their own screens.
    public let bluetooth: VirdeeBluetoothIssue?
    /// Vendor error code — stable, branch on this.
    public let errorCode: String?
    /// Vendor error text — for humans, not stable, and not always worth showing.
    public let errorMessage: String?
    /// Consecutive failures in this session. Useful for escalating the copy —
    /// "try again" first, "visit the front desk" after a few.
    public let errorCount: Int

    /// The SDK's own progress line, e.g. while provisioning.
    public let statusMessage: String?

    /// Seconds left in the unlock window, and 0…1 of it elapsed.
    public let unlockRemainingSeconds: Int
    public let unlockProgress: Double

    /// Room number for the key card, from the access grant's resource.
    public let roomName: String?
    /// Floor. Wired through, but the backend does not populate it yet, so expect
    /// `nil` — the field exists so the contract does not have to change later.
    public let floor: String?

    public static let idle = VirdeeMobileKeyState(
        phase: .idle,
        isRecovering: false,
        bluetooth: nil,
        errorCode: nil,
        errorMessage: nil,
        errorCount: 0,
        statusMessage: nil,
        unlockRemainingSeconds: 0,
        unlockProgress: 0,
        roomName: nil,
        floor: nil
    )
}

// MARK: - Controller

/// Drives the digital key with no Virdee UI at all — the host owns the screen.
///
/// Obtained from `VirdeeService.makeMobileKeyController(...)`, and tied to the
/// lifetime of whatever presents it: call `stop()` when that goes away.
///
/// Virdee allow only one consumer of the key per access grant, so this and
/// `presentMobileKey()` are mutually exclusive — starting one while the other is
/// live is refused and logged.
public protocol VirdeeMobileKeyController: AnyObject {

    /// Replays the current state to each new subscriber, so a screen that
    /// subscribes late still renders correctly.
    var state: AnyPublisher<VirdeeMobileKeyState, Never> { get }
    var currentState: VirdeeMobileKeyState { get }

    /// Mounts the headless surface and provisions the key.
    ///
    /// With `autoActivate` the unlock starts by itself the moment the key is
    /// ready — the screen goes straight to "hold your phone near the reader"
    /// with no button. Pass `false` to drive it with `openLock()`.
    func start(autoActivate: Bool)

    func openLock()
    /// Back to `.ready` without an error.
    func cancelUnlock()
    /// The "Try Again" button. Retries the unlock when a key exists, and re-runs
    /// provisioning when it does not — the same button covers both, because a guest
    /// cannot tell "the key could not be issued" from "the door did not open".
    func retry()
    /// Clears the error without retrying.
    func dismissError()

    /// Unmounts the surface. The JS runtime stays warm, as everywhere else.
    func stop()
}

public extension VirdeeMobileKeyController {
    /// Matches the design, where unlocking begins as soon as the screen settles.
    func start() { start(autoActivate: true) }
}
