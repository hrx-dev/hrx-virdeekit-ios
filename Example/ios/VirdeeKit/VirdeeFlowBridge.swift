//
// VirdeeFlowBridge.swift
// VirdeeKit
//
// Created by Oleksandr Malinchuk on 31.07.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import Foundation

// See VirdeeRuntime.swift — a plain import would leak React into
// VirdeeKit.swiftinterface and force the host app to resolve it too.
@_implementationOnly import React

/// JS -> native channel. React Native instantiates this itself, so it forwards through
/// static sinks rather than holding a reference to the service.
///
/// The JS contract lives in Example/index.js and must stay in sync with these names.
@objc(VirdeeFlowBridge)
final class VirdeeFlowBridge: NSObject {

    static var onRequirements: (([String: Any]) -> Void)?
    static var onShowVerifyId: ((String) -> Void)?
    static var onShowMobileKeyButton: (() -> Void)?
    static var onCloseClearIDV: (() -> Void)?
    static var onCloseMobileKey: (() -> Void)?
    static var onFlowEvent: ((String, String, [String: Any]) -> Void)?
    static var onFailedToStart: ((String, String) -> Void)?
    /// Headless mobile key only — one snapshot of `useMobileKey` state per change.
    static var onMobileKeyState: (([String: Any]) -> Void)?

    @objc(failedToStart:)
    func failedToStart(_ payload: NSDictionary?) {
        let dict = payload as? [String: Any] ?? [:]
        let code = dict["code"] as? String ?? "UNKNOWN"
        let message = dict["message"] as? String ?? "Virdee SDK failed to initialise"
        main { Self.onFailedToStart?(code, message) }
    }

    @objc(setRequirements:)
    func setRequirements(_ summary: NSDictionary) {
        let dict = summary as? [String: Any] ?? [:]
        main { Self.onRequirements?(dict) }
    }

    @objc(showVerifyIdButton:)
    func showVerifyIdButton(_ accessGrantId: String) {
        main { Self.onShowVerifyId?(accessGrantId) }
    }

    /// JS can ask to open CLEAR directly; VirdeeKit routes it through the same path
    /// the host would use, so presentation stays in one place.
    @objc(showClearIDV:)
    func showClearIDV(_ accessGrantId: String) {
        main { Self.onShowVerifyId?(accessGrantId) }
    }

    @objc(closeClearIDV)
    func closeClearIDV() {
        main { Self.onCloseClearIDV?() }
    }

    @objc(showMobileKeyButton)
    func showMobileKeyButton() {
        main { Self.onShowMobileKeyButton?() }
    }

    @objc(closeMobileKey)
    func closeMobileKey() {
        main { Self.onCloseMobileKey?() }
    }

    @objc(mobileKeyState:)
    func mobileKeyState(_ state: NSDictionary) {
        let dict = state as? [String: Any] ?? [:]
        main { Self.onMobileKeyState?(dict) }
    }

    @objc(onVirdeeEvent:event:payload:)
    func onVirdeeEvent(_ flow: String, event: String, payload: NSDictionary?) {
        let dict = payload as? [String: Any] ?? [:]
        main { Self.onFlowEvent?(flow, event, dict) }
    }

    /// The SDK's own JavaScript console, forwarded from index.js.
    ///
    /// Without this, anything the controller logs is invisible: it runs in a
    /// 1×1 transparent surface, so React Native's redbox never shows, and in a
    /// release build there is no Metro to print to either.
    @objc(log:message:)
    func log(_ level: String, message: String) {
        switch level {
        case "error": VirdeeLog.shared.error("js", message)
        case "warn":  VirdeeLog.shared.warning("js", message)
        default:      VirdeeLog.shared.debug("js", message)
        }
    }

    @objc static func requiresMainQueueSetup() -> Bool { false }

    private func main(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}

/// Native -> JS. Re-arms the already-mounted controller surface so a repeat flow
/// re-reads requirements. Rebuilding the surface instead would re-run
/// VirdeeSDK.reset()/init() and hang on "Checking requirements…".
@objc(VirdeeRestartEmitter)
final class VirdeeRestartEmitter: RCTEventEmitter {

    /// Must match `emitter.addListener('VirdeeRestart', …)` in Example/index.js.
    /// A mismatch here fails silently: sendEvent goes nowhere, no error is raised,
    /// and refresh() quietly stops re-reading requirements.
    private static let restartEvent = "VirdeeRestart"

    /// Drives the headless mobile key surface. Same silent-failure rule as above —
    /// it must match `addListener('VirdeeMobileKeyCommand', …)` in Example/index.js.
    private static let mobileKeyCommandEvent = "VirdeeMobileKeyCommand"

    private static weak var current: VirdeeRestartEmitter?
    private var hasListeners = false

    override init() {
        super.init()
        Self.current = self
    }

    override static func requiresMainQueueSetup() -> Bool { false }

    override func supportedEvents() -> [String] {
        [Self.restartEvent, Self.mobileKeyCommandEvent]
    }

    override func startObserving() { hasListeners = true }
    override func stopObserving() { hasListeners = false }

    static func emitRestart() {
        guard let emitter = current, emitter.hasListeners else { return }
        emitter.sendEvent(withName: Self.restartEvent, body: nil)
    }

    /// `command` is one of initialize / openLock / cancelUnlock / retry / dismissError;
    /// the switch that consumes them lives in VirdeeMobileKeyHeadless in index.js.
    @discardableResult
    static func emitMobileKeyCommand(_ command: String) -> Bool {
        guard let emitter = current, emitter.hasListeners else {
            VirdeeLog.shared.warning("bridge", "no JS listener for \(command) — command dropped")
            return false
        }
        VirdeeLog.shared.debug("bridge", "→ js mobileKey.\(command)")
        emitter.sendEvent(withName: Self.mobileKeyCommandEvent, body: ["command": command])
        return true
    }
}
