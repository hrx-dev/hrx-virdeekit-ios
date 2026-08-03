//
// VirdeeServiceImpl.swift
// VirdeeKit
//
// Created by Oleksandr Malinchuk on 31.07.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import UIKit
import Combine

/// Module names registered in Example/index.js. Changing one means changing both.
private enum Surface {
    static let controller = "VirdeeController"
    static let clearIDV = "VirdeeClearIDV"
    static let mobileKey = "VirdeeMobileKey"
}

public final class VirdeeServiceImpl: VirdeeService {

    private let runtime = VirdeeRuntime.shared
    private let subject = PassthroughSubject<VirdeeEvent, Never>()

    private var session: VirdeeSession?
    private var controllerView: UIView?
    private var clearIDVWindow: UIWindow?
    private var mobileKeyWindow: UIWindow?
    private var pendingIDVAccessGrantId: String?

    public private(set) var requirements: [VirdeeRequirement] = []

    public var events: AnyPublisher<VirdeeEvent, Never> { subject.eraseToAnyPublisher() }

    public var logLevel: VirdeeLogLevel {
        get { VirdeeLog.shared.level }
        set { VirdeeLog.shared.level = newValue }
    }

    public init(configuration: VirdeeConfiguration = .default) {
        VirdeeLog.shared.configure(configuration)
        VirdeeLog.shared.info("service", "VirdeeKit \(VirdeeKitVersion.version) (sdk-core \(VirdeeKitVersion.sdkCore))")
        wireBridge()
    }

    // MARK: - Lifecycle

    public func start(session: VirdeeSession) {
        self.session = session
        VirdeeLog.shared.info(
            "service",
            "start — grant \(Redact.id(session.accessGrantId)), env \(session.environment.rawValue)"
        )
        runtime.warmUp()

        // Already mounted → re-arm in place. Rebuilding would re-run
        // VirdeeSDK.reset()/init() and hang on "Checking requirements…".
        guard controllerView == nil else {
            VirdeeLog.shared.debug("service", "controller already mounted — re-arming")
            VirdeeRestartEmitter.emitRestart()
            return
        }

        guard let view = runtime.makeSurface(
            moduleName: Surface.controller,
            initialProperties: [
                "accessGrantId": session.accessGrantId,
                "accessToken": session.accessToken,
                "env": session.environment.rawValue,
            ]
        ) else {
            let message = "Could not create the \(Surface.controller) surface"
            VirdeeLog.shared.error("service", message)
            subject.send(.failedToStart(message: message))
            return
        }

        // The controller renders nothing — it only runs the SDK. Kept tiny,
        // transparent and non-interactive so the host UI is untouched.
        view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        view.alpha = 0
        view.isUserInteractionEnabled = false
        hostWindow()?.addSubview(view)
        controllerView = view
        VirdeeLog.shared.debug("service", "hidden \(Surface.controller) surface mounted")
    }

    public func refresh() {
        guard controllerView != nil else { return }
        VirdeeRestartEmitter.emitRestart()
    }

    public func stop() {
        VirdeeLog.shared.info("service", "stop — tearing down surfaces and the JS runtime")
        dismiss(&clearIDVWindow)
        dismiss(&mobileKeyWindow)
        controllerView?.removeFromSuperview()
        controllerView = nil
        requirements = []
        session = nil
        runtime.shutdown()
    }

    // MARK: - Presentation

    public func presentIDVerification() {
        guard let accessGrantId = pendingIDVAccessGrantId ?? session?.accessGrantId else { return }
        guard clearIDVWindow == nil else { return }
        clearIDVWindow = makeOverlay(moduleName: Surface.clearIDV, accessGrantId: accessGrantId)
    }

    public func presentMobileKey() {
        guard let accessGrantId = session?.accessGrantId, mobileKeyWindow == nil else { return }
        mobileKeyWindow = makeOverlay(moduleName: Surface.mobileKey, accessGrantId: accessGrantId)
    }

    /// Virdee's screens are hosted in a transparent key `UIWindow` rather than a modal
    /// view controller. `react-native-screens` presents its own modals from the key
    /// window's root controller, so anything else breaks the SDK's internal navigation.
    private func makeOverlay(moduleName: String, accessGrantId: String) -> UIWindow? {
        guard let scene = activeScene() else {
            VirdeeLog.shared.error("service", "no foreground window scene — cannot present \(moduleName)")
            return nil
        }
        guard let rootView = runtime.makeSurface(
            moduleName: moduleName,
            initialProperties: ["accessGrantId": accessGrantId]
        ) else {
            VirdeeLog.shared.error("service", "could not create the \(moduleName) surface")
            return nil
        }
        VirdeeLog.shared.info("service", "presenting \(moduleName) in an overlay window")

        let container = UIView()
        container.backgroundColor = .clear

        // Shown during the RN mount gap; the SDK draws its own opaque UI on top.
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        container.addSubview(spinner)

        rootView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rootView)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            rootView.topAnchor.constraint(equalTo: container.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rootView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let controller = UIViewController()
        controller.view = container

        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.backgroundColor = .clear
        window.isOpaque = false
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        return window
    }

    private func dismiss(_ window: inout UIWindow?) {
        guard window != nil else { return }
        // Hand key status back to the app's own window before releasing this one.
        if let scene = activeScene(),
           let host = scene.windows.first(where: { $0 !== window }) {
            host.makeKey()
        }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    // MARK: - Bridge wiring

    private func wireBridge() {
        VirdeeFlowBridge.onFailedToStart = { [weak self] code, message in
            VirdeeLog.shared.error("service", "SDK failed to start [\(code)] \(message)")
            self?.subject.send(.failedToStart(message: "[\(code)] \(message)"))
        }

        VirdeeFlowBridge.onRequirements = { [weak self] summary in
            guard let self else { return }
            VirdeeLog.shared.debug("bridge", "setRequirements \(summary)")
            let raw = summary["requirements"] as? [[String: Any]] ?? []
            self.requirements = raw.map {
                VirdeeRequirement(
                    type: $0["type"] as? String ?? "UNKNOWN",
                    status: $0["status"] as? String ?? "UNKNOWN"
                )
            }
            VirdeeLog.shared.info(
                "service",
                "requirements — " + (self.requirements.isEmpty
                    ? "none"
                    : self.requirements.map { "\($0.type)=\($0.status)" }.joined(separator: ", "))
            )
            self.subject.send(.requirementsLoaded(self.requirements))
        }

        VirdeeFlowBridge.onShowVerifyId = { [weak self] accessGrantId in
            VirdeeLog.shared.info("service", "ID verification required")
            self?.pendingIDVAccessGrantId = accessGrantId
            self?.subject.send(.idVerificationRequired)
        }

        VirdeeFlowBridge.onShowMobileKeyButton = { [weak self] in
            VirdeeLog.shared.info("service", "mobile key available")
            self?.subject.send(.mobileKeyAvailable)
        }

        VirdeeFlowBridge.onCloseClearIDV = { [weak self] in
            guard let self else { return }
            self.dismiss(&self.clearIDVWindow)
        }

        VirdeeFlowBridge.onCloseMobileKey = { [weak self] in
            guard let self else { return }
            self.dismiss(&self.mobileKeyWindow)
        }

        VirdeeFlowBridge.onFlowEvent = { [weak self] flow, event, payload in
            guard let self else { return }
            let outcome = Self.outcome(event: event, payload: payload)

            switch outcome {
            case .failed(let code, let message):
                VirdeeLog.shared.error("flow", "\(flow).\(event) [\(code)] \(message)")
            case .progress:
                VirdeeLog.shared.debug("flow", "\(flow).\(event) \(payload)")
            default:
                VirdeeLog.shared.info("flow", "\(flow).\(event)")
            }

            switch flow {
            case "idv":
                if case .succeeded = outcome {
                    self.markIDVerificationComplete()
                }
                self.subject.send(.idVerification(outcome))
            case "mobileKey":
                self.subject.send(.mobileKey(outcome))
            default:
                VirdeeLog.shared.warning("flow", "unknown flow '\(flow)' — event dropped")
            }
        }
    }

    private func markIDVerificationComplete() {
        requirements = requirements.map {
            $0.type == "ID_VERIFICATION"
                ? VirdeeRequirement(type: $0.type, status: "COMPLETED")
                : $0
        }
        pendingIDVAccessGrantId = nil
        subject.send(.requirementsLoaded(requirements))
    }

    private static func outcome(event: String, payload: [String: Any]) -> VirdeeFlowOutcome {
        switch event {
        case "success":
            return .succeeded
        case "cancel":
            return .cancelled
        case "close":
            return .closed
        case "error":
            // index.js normalises every error through toPayload():
            //   { code: code ?? name ?? 'UNKNOWN', message, vendor? }
            let code = payload["code"] as? String ?? "UNKNOWN"
            let message = payload["message"] as? String ?? "Unknown Virdee error"
            return .failed(code: code, message: message)
        default:
            let name = (payload["event"] as? [String: Any])?["type"] as? String ?? event
            return .progress(name)
        }
    }

    // MARK: - Window helpers

    private func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private func hostWindow() -> UIWindow? {
        activeScene()?.windows.first { $0.isKeyWindow } ?? activeScene()?.windows.first
    }
}
