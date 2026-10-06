//
// VirdeeRuntime.swift
// VirdeeKit
//
// Created by Oleksandr Malinchuk on 31.07.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import UIKit

// @_implementationOnly keeps these out of VirdeeKit.swiftinterface. A plain
// `import` is recorded as a public dependency of the module even when no React
// type is exposed, and then the host app cannot compile without React Native
// headers on its own search paths — which would defeat the whole point of
// shipping a binary facade. Requires BUILD_LIBRARY_FOR_DISTRIBUTION, which this
// target sets.
@_implementationOnly import React
@_implementationOnly import React_RCTAppDelegate
@_implementationOnly import ReactAppDependencyProvider

/// Owns the single React Native runtime. Internal — the host app only sees `VirdeeService`.
///
/// All Virdee surfaces share one JS runtime on purpose: the `VirdeeSDK` singleton and
/// its access-grant store live there, so a second runtime would mean a second, empty session.
final class VirdeeRuntime {

    static let shared = VirdeeRuntime()

    private var delegate: FactoryDelegate?
    private var factory: RCTReactNativeFactory?

    private init() {}

    var isWarm: Bool { factory != nil }

    /// Spinning up the runtime costs a few hundred milliseconds, so it must never
    /// run at app launch — only when the guest actually opens a Virdee flow.
    func warmUp() {
        guard factory == nil else { return }
        let delegate = FactoryDelegate()
        delegate.dependencyProvider = RCTAppDependencyProvider()
        self.delegate = delegate
        self.factory = RCTReactNativeFactory(delegate: delegate)
    }

    func makeSurface(moduleName: String, initialProperties: [String: Any]) -> UIView? {
        warmUp()
        let view = factory?.rootViewFactory.view(
            withModuleName: moduleName,
            initialProperties: initialProperties
        )
        // Transparent, or the RN mount gap flashes an opaque background over the host app.
        view?.backgroundColor = .clear
        view?.isOpaque = false
        return view
    }

    // There is deliberately no shutdown(). Releasing RCTReactNativeFactory and building
    // a second runtime in the same process crashed in production, two ways:
    //
    //   nitro::install → HybridObjectPrototype::createPrototype
    //                  → HermesRuntimeImpl::createFunctionFromHostFunction
    //
    //   -[RCTNetworking prioritizedHandlers] → +[NSArray arrayWithObjects:count:]
    //   (nil handler) while the JS thread ran -[RCTInstance invalidate]
    //
    // react-native-nitro-modules keeps process-global static caches keyed by the raw
    // `jsi::Runtime*` — PropNameIDCache, CommonGlobals, Prototype — and clears none of
    // them, so a runtime allocated at a recycled address inherits references into a
    // freed one. The second crash is plainer: in-flight requests outlive invalidate.
    //
    // Virdee confirmed (Oct 2026) that the SDK is meant to live for the whole app and
    // that there is no supported way to end a session other than unmounting surfaces.
    // Ending a flow is VirdeeServiceImpl.stop(); the runtime stays.
}

private final class FactoryDelegate: RCTDefaultReactNativeFactoryDelegate {

    override func sourceURL(for bridge: RCTBridge) -> URL? { bundleURL() }

    override func bundleURL() -> URL? {
        #if DEBUG
        // Metro, for whoever develops the Virdee screens in Example/.
        return RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
        #else
        // Release: the bundle ships inside this framework, so resolve against the
        // framework bundle — Bundle.main is the host app and has no copy.
        let framework = Bundle(for: VirdeeRuntime.self)
        if let url = framework.url(forResource: "main", withExtension: "jsbundle") {
            return url
        }
        if let nested = framework.url(forResource: "VirdeeKitResources", withExtension: "bundle"),
           let resources = Bundle(url: nested) {
            return resources.url(forResource: "main", withExtension: "jsbundle")
        }
        assertionFailure("VirdeeKit: main.jsbundle missing from the framework bundle")
        return nil
        #endif
    }
}
