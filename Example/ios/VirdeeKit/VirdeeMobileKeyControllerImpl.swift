//
// VirdeeMobileKeyControllerImpl.swift
// VirdeeKit
//
// Created by Oleksandr Malinchuk on 12.10.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import Combine
import Foundation

/// Native half of the headless key: turns `useMobileKey` snapshots into
/// `VirdeeMobileKeyState`, and the protocol's methods into JS commands.
///
/// Internal — hosts only ever see `VirdeeMobileKeyController`.
final class VirdeeMobileKeyControllerImpl: VirdeeMobileKeyController {

    private weak var service: VirdeeServiceImpl?
    private let unlockTimeout: TimeInterval
    private let subject = CurrentValueSubject<VirdeeMobileKeyState, Never>(.idle)
    private var isRunning = false

    init(service: VirdeeServiceImpl, unlockTimeout: TimeInterval) {
        self.service = service
        self.unlockTimeout = unlockTimeout
    }

    deinit {
        // A host that forgets stop() would otherwise leave the surface mounted and
        // the SEOS session running with nothing listening.
        if isRunning {
            VirdeeLog.shared.warning("flow", "mobile key controller deallocated while running — unmounting")
            service?.unmountMobileKeyHeadless()
        }
    }

    // MARK: - VirdeeMobileKeyController

    var state: AnyPublisher<VirdeeMobileKeyState, Never> { subject.eraseToAnyPublisher() }
    var currentState: VirdeeMobileKeyState { subject.value }

    func start(autoActivate: Bool) {
        guard !isRunning else {
            VirdeeLog.shared.debug("flow", "mobile key controller already started")
            return
        }
        guard let service else { return }

        isRunning = service.mountMobileKeyHeadless(
            autoActivate: autoActivate,
            unlockTimeout: unlockTimeout
        )
    }

    func openLock()     { send("openLock") }
    func cancelUnlock() { send("cancelUnlock") }
    func retry()        { send("retry") }
    func dismissError() { send("dismissError") }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        service?.unmountMobileKeyHeadless()
        subject.send(.idle)
    }

    // MARK: - Internal

    /// Called by the service for every snapshot the JS side pushes.
    func apply(_ snapshot: [String: Any]) {
        guard isRunning else { return }

        let code = snapshot["errorCode"] as? String
        let phase = VirdeeMobileKeyPhase(rawValue: Self.phaseName(snapshot["status"] as? String)) ?? .idle

        let next = VirdeeMobileKeyState(
            phase: phase,
            isRecovering: snapshot["isRecovering"] as? Bool ?? false,
            bluetooth: VirdeeBluetoothIssue(code: code),
            errorCode: code,
            errorMessage: snapshot["errorMessage"] as? String,
            errorCount: snapshot["errorCount"] as? Int ?? 0,
            statusMessage: snapshot["statusMessage"] as? String,
            unlockRemainingSeconds: snapshot["unlockRemainingSeconds"] as? Int ?? 0,
            unlockProgress: snapshot["unlockProgress"] as? Double ?? 0,
            roomName: snapshot["roomName"] as? String,
            floor: snapshot["floor"] as? String
        )

        // The hook re-renders more often than the state meaningfully changes, and a
        // host binding a label to every emission would thrash.
        guard next != subject.value else { return }

        VirdeeLog.shared.debug("flow", "mobileKey \(next.phase.rawValue)"
            + (next.bluetooth.map { " bluetooth:\($0.rawValue)" } ?? "")
            + (next.errorCode.map { " [\($0)]" } ?? ""))
        subject.send(next)
    }

    // MARK: - Private

    /// `provisioning_key` is the only name that is not already camelCase.
    private static func phaseName(_ status: String?) -> String {
        status == "provisioning_key" ? "provisioningKey" : (status ?? "idle")
    }

    private func send(_ command: String) {
        guard isRunning else {
            VirdeeLog.shared.warning("flow", "\(command) ignored — controller is not started")
            return
        }
        VirdeeRestartEmitter.emitMobileKeyCommand(command)
    }
}
