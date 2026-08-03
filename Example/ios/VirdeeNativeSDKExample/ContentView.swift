//
// ContentView.swift
// VirdeeNativeSDKExample
//
// Created by Oleksandr Malinchuk on 31.07.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import SwiftUI
import Combine
import VirdeeKit

/// Everything below talks to VirdeeKit through `VirdeeService` only. There is no
/// `import React`, no module names, no bridge — which is the point of the harness.
final class HarnessModel: ObservableObject {

    @Published var log: [String] = []
    @Published var requirements: [VirdeeRequirement] = []
    @Published var canVerifyId = false
    @Published var canOpenKey = false
    @Published var started = false

    // The harness exists to diagnose, so it runs at .debug and also mirrors every
    // entry onto its own screen — the same closure a host would use to forward
    // selectively into its own logging stack.
    private let virdee: VirdeeService = VirdeeServiceImpl(
        configuration: VirdeeConfiguration(logLevel: .debug)
    )
    private var cancellables = Set<AnyCancellable>()

    init() {
        note("VirdeeKit \(VirdeeKitVersion.version) · sdk-core \(VirdeeKitVersion.sdkCore)")

        virdee.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    func start() {
        guard VirdeeCredentials.isConfigured else {
            note("No credentials — fill in VirdeeCredentials.swift")
            return
        }
        started = true
        note("start(session:) — access grant \(VirdeeCredentials.accessGrantId.prefix(8))…")
        virdee.start(session: VirdeeCredentials.session)
    }

    func verifyId() { virdee.presentIDVerification() }
    func openKey() { virdee.presentMobileKey() }
    func refresh() { note("refresh()"); virdee.refresh() }

    func stop() {
        virdee.stop()
        started = false
        canVerifyId = false
        canOpenKey = false
        requirements = []
        note("stop()")
    }

    private func handle(_ event: VirdeeEvent) {
        switch event {
        case .requirementsLoaded(let items):
            requirements = items
            note("requirementsLoaded — \(items.count) item(s)")

        case .idVerificationRequired:
            canVerifyId = true
            note("idVerificationRequired")

        case .mobileKeyAvailable:
            canOpenKey = true
            note("mobileKeyAvailable")

        case .idVerification(let outcome):
            note("idVerification → \(describe(outcome))")

        case .mobileKey(let outcome):
            note("mobileKey → \(describe(outcome))")

        case .failedToStart(let message):
            note("failedToStart — \(message)")
        }
    }

    private func describe(_ outcome: VirdeeFlowOutcome) -> String {
        switch outcome {
        case .succeeded: return "succeeded"
        case .cancelled: return "cancelled"
        case .closed: return "closed"
        case .progress(let step): return "progress(\(step))"
        case .failed(let code, let message): return "failed [\(code)] \(message)"
        }
    }

    private func note(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(stamp)  \(line)")
    }
}

struct ContentView: View {
    @StateObject private var model = HarnessModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VirdeeKit harness")
                .font(.title2.bold())

            HStack {
                Button(model.started ? "Restart" : "Start") { model.start() }
                    .buttonStyle(.borderedProminent)
                Button("Refresh") { model.refresh() }
                    .disabled(!model.started)
                Button("Stop") { model.stop() }
                    .disabled(!model.started)
            }

            HStack {
                Button("Verify ID") { model.verifyId() }
                    .disabled(!model.canVerifyId)
                Button("Mobile key") { model.openKey() }
                    .disabled(!model.canOpenKey)
            }

            if !model.requirements.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Requirements").font(.headline)
                    ForEach(model.requirements, id: \.type) { requirement in
                        HStack {
                            Image(systemName: requirement.isComplete
                                  ? "checkmark.circle.fill" : "circle")
                            Text(requirement.displayName)
                            Spacer()
                            Text(requirement.status).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }

            Text("Events").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer()
        }
        .padding()
    }
}
