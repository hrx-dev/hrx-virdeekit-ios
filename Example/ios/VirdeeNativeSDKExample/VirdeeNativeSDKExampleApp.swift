//
// VirdeeNativeSDKExampleApp.swift
// VirdeeNativeSDKExample
//
// Created by Oleksandr Malinchuk on 31.07.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

import SwiftUI

/// Harness for VirdeeKit. Deliberately a plain SwiftUI app with no `import React`
/// anywhere — if this compiles and runs, the facade really does hide React Native.
///
/// The RN runtime is not started here. VirdeeService warms it lazily inside
/// start(), which is the behaviour HRX depends on for launch time.
@main
struct VirdeeNativeSDKExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
