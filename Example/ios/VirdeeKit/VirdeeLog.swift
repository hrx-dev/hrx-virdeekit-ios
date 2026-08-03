//
// VirdeeLog.swift
// VirdeeKit
//
// Created by Oleksandr Malinchuk on 31.07.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import Foundation

// MARK: - Public configuration

public enum VirdeeLogLevel: Int, Comparable, Sendable {
    /// Nothing at all, not even failures.
    case off = 0
    /// Failures only. The default: quiet, but a broken integration still shows.
    case error = 1
    /// Recoverable oddities — an unknown event name, a window dismissed twice.
    case warning = 2
    /// Lifecycle: sessions starting, surfaces mounting, flows opening.
    case info = 3
    /// Everything, including every bridge callback and the SDK's own JS console.
    /// Verbose by design — for diagnosing, not for shipping.
    case debug = 4

    public static func < (lhs: VirdeeLogLevel, rhs: VirdeeLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One line of VirdeeKit diagnostics. Structured rather than a bare string so a
/// host can filter by level or category instead of parsing text.
public struct VirdeeLogEntry: Sendable {
    public let level: VirdeeLogLevel
    /// `service`, `runtime`, `bridge`, `flow`, or `js` — the last being the
    /// SDK's own JavaScript console, forwarded from React Native.
    public let category: String
    public let message: String
    public let date: Date
}

public struct VirdeeConfiguration {
    public var logLevel: VirdeeLogLevel

    /// Optional extra sink, on top of the console output which always happens.
    ///
    /// A closure rather than a protocol on purpose: there is no type to conform
    /// to, and selective forwarding is a `guard` at the call site. VirdeeKit
    /// never learns what is on the other end.
    ///
    ///     VirdeeConfiguration(logLevel: .info) { entry in
    ///         guard entry.level == .error else { return }
    ///         MyLogger.log(entry.message)
    ///     }
    ///
    /// Called on whichever queue produced the entry — do not assume main.
    public var logHandler: (@Sendable (VirdeeLogEntry) -> Void)?

    public init(
        logLevel: VirdeeLogLevel = .error,
        logHandler: (@Sendable (VirdeeLogEntry) -> Void)? = nil
    ) {
        self.logLevel = logLevel
        self.logHandler = logHandler
    }

    public static let `default` = VirdeeConfiguration()
}

// MARK: - Internal logger

/// Prints to the Xcode console. Deliberately has no dependency on anything
/// outside VirdeeKit — no host logging service, no third-party sink.
///
/// If production diagnostics are ever needed, swapping `print` for `os_log`
/// here is a local change; nothing else has to move.
final class VirdeeLog: @unchecked Sendable {

    static let shared = VirdeeLog()

    private let lock = NSLock()
    private var _level: VirdeeLogLevel = .error
    private var _handler: (@Sendable (VirdeeLogEntry) -> Void)?

    private init() {}

    var level: VirdeeLogLevel {
        get { lock.withLock { _level } }
        set { lock.withLock { _level = newValue } }
    }

    func configure(_ configuration: VirdeeConfiguration) {
        lock.withLock {
            _level = configuration.logLevel
            _handler = configuration.logHandler
        }
    }

    func error(_ category: String, _ message: @autoclosure () -> String) {
        emit(.error, category, message)
    }

    func warning(_ category: String, _ message: @autoclosure () -> String) {
        emit(.warning, category, message)
    }

    func info(_ category: String, _ message: @autoclosure () -> String) {
        emit(.info, category, message)
    }

    func debug(_ category: String, _ message: @autoclosure () -> String) {
        emit(.debug, category, message)
    }

    /// `message` is an autoclosure so building the string costs nothing when the
    /// level filters it out — which matters for per-callback debug logging.
    private func emit(
        _ level: VirdeeLogLevel,
        _ category: String,
        _ message: () -> String
    ) {
        let (active, handler) = lock.withLock { (_level, _handler) }
        guard active != .off, level <= active else { return }

        let tag: String
        switch level {
        case .error:   tag = "ERROR"
        case .warning: tag = "WARN "
        case .info:    tag = "INFO "
        case .debug:   tag = "DEBUG"
        case .off:     return
        }

        let text = Redact.tokens(in: message())
        print("[VirdeeKit][\(tag)][\(category)] \(text)")

        handler?(
            VirdeeLogEntry(level: level, category: category, message: text, date: Date())
        )
    }
}

// MARK: - Redaction

enum Redact {
    private static let jwt = try? NSRegularExpression(
        pattern: "eyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"
    )

    /// Access tokens must not reach the console: logs get screenshotted, pasted
    /// into tickets and captured by crash reporters.
    static func tokens(in text: String) -> String {
        guard let jwt else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return jwt.stringByReplacingMatches(
            in: text, range: range, withTemplate: "<redacted-jwt>"
        )
    }

    /// Keeps an identifier recognisable without printing it in full.
    static func id(_ value: String) -> String {
        value.count <= 8 ? value : String(value.prefix(8)) + "…"
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
