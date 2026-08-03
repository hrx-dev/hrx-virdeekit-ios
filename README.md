# VirdeeKit

Swift package that wraps the Virdee guest-experience SDK behind a native interface.

Virdee ship **only** a React Native SDK. HRX is a native Swift app on SwiftPM with no
CocoaPods and no Node toolchain. VirdeeKit exists so that stays true: React Native,
`node_modules`, CocoaPods and the JS bundle all live inside a prebuilt
`VirdeeKit.xcframework`, and HRX consumes it as an ordinary SwiftPM dependency.

Built on Virdee's own native host example, which they supply on request — the public
docs pages for native integration are published empty.

> **Status: proof of concept.** The framework builds and the SDK runs, but the flows
> have never been driven end to end: Virdee's example ships placeholder credentials
> (`YOUR_ACCESS_GRANT_ID` / `YOUR_ACCESS_TOKEN`) and the app stops at
> "Checking requirements…". Real test credentials are the remaining blocker.

## Using it from HRX

```swift
import VirdeeKit

let virdee: VirdeeService = VirdeeServiceImpl(
    configuration: VirdeeConfiguration(logLevel: .error)
)

virdee.events
    .receive(on: DispatchQueue.main)
    .sink { event in
        switch event {
        case .requirementsLoaded(let requirements):
            render(requirements)                  // your own UI
        case .idVerificationRequired:
            showVerifyIdButton()                  // then call presentIDVerification()
        case .mobileKeyAvailable:
            showKeyButton()                       // then call presentMobileKey()
        case .idVerification(.succeeded):
            markCheckInComplete()
        case .failedToStart(let message):
            report(message)
        default:
            break
        }
    }
    .store(in: &cancellables)

// Credentials come from the HRX backend, never from the client.
virdee.start(session: VirdeeSession(
    accessGrantId: grant.id,
    accessToken: grant.token,
    environment: .production
))
```

`VirdeeService` is the entire public surface. Nothing React Native leaks past it.

**VirdeeKit owns presentation.** It does not hand back a `UIViewController`: the SDK's
screens are mounted into a transparent key `UIWindow`, which is what lets
`react-native-screens` present its own modals correctly. Handing the host a plain
view controller breaks the SDK's internal navigation.

## Logging

```swift
// at init
VirdeeServiceImpl(configuration: VirdeeConfiguration(logLevel: .info))

// or at any point afterwards, e.g. from a hidden developer menu
virdee.logLevel = .debug
virdee.logLevel = .off
```

| Level | Shows |
|---|---|
| `.off` | nothing |
| `.error` | failures only — **the default** |
| `.warning` | plus recoverable oddities |
| `.info` | plus lifecycle: sessions, surfaces, flows |
| `.debug` | plus every bridge callback and the SDK's own JS console |

Output goes to the Xcode console, prefixed `[VirdeeKit][LEVEL][category]`, where
category is one of `service`, `runtime`, `bridge`, `flow` or `js`.

**`js` is the one that matters.** The controller surface runs at 1×1 with
`alpha = 0`, so React Native's redbox never appears, and a release build has no
Metro either — everything the SDK said about its own failures used to be lost.
It is now forwarded through the bridge, which is how this turned up:

```
[VirdeeKit][ERROR][js] [GraphQL Error] "Context creation failed: Unauthorized"
[VirdeeKit][ERROR][js] [VirdeeSDK] Initialization failed
```

**JWTs are redacted** before anything is printed. React Native logs `initialProps`
verbatim when mounting a surface, so at `.debug` the access token would otherwise
go straight to the console — and from there into screenshots and tickets.

### Forwarding elsewhere

`logHandler` is an optional extra sink; console output always happens regardless.

```swift
VirdeeConfiguration(logLevel: .info) { entry in
    guard entry.level == .error else { return }   // filter as you like
    MyLogger.log(entry.message)
}
```

A closure rather than a protocol: nothing to conform to, and VirdeeKit never
learns what is on the other end. `VirdeeLogEntry` carries `level`, `category`,
`message` and `date`, so filtering does not mean parsing strings. Called on
whichever queue produced the entry — do not assume main.

### What the host app must still provide

A binary framework cannot inject these — they belong to HRX:

- `Info.plist`: `NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, `NSCameraUsageDescription`, and
  `NSAppTransportSecurity` with `NSAllowsArbitraryLoads = false`
- URL scheme `virdee-sdk` — CLEAR ID verification captures its OAuth redirect on
  `virdee-sdk://clear`. `SceneDelegate` must route those URLs into React Native and
  everything else to the existing `DeeplinkService`.
- `UIBackgroundModes: bluetooth-central`, only for background lock communication
- optionally `com.apple.developer.passkit.pass-presentation-suppression`, which
  suppresses the Wallet sheet during the BLE handshake

## How the flow works

React Native never becomes "the app". The native side decides what to show and when.

1. `start(session:)` mounts a **hidden** `VirdeeController` surface — 1×1 point,
   `alpha = 0`, non-interactive. It runs `VirdeeSDK.init()`, recovers the access grant
   and reports its requirements back through the bridge.
2. VirdeeKit republishes those as `.requirementsLoaded`, plus `.idVerificationRequired`
   and `.mobileKeyAvailable` signals. **The host renders its own UI from these.**
3. On your button tap, `presentIDVerification()` / `presentMobileKey()` mount the
   `VirdeeClearIDV` / `VirdeeMobileKey` surfaces in overlay windows.
4. Lifecycle callbacks arrive as `.idVerification(...)` / `.mobileKey(...)`.

All surfaces share one JS runtime, so the `VirdeeSDK` singleton and its access-grant
store are shared. `refresh()` re-arms the existing controller; it never rebuilds it,
because rebuilding re-runs `VirdeeSDK.reset()/init()` and hangs on "Checking requirements…".

## Repo layout

```
Package.swift                     binaryTarget(path:) — no artifact hosting needed
Sources/VirdeeKit/                thin wrapper carrying linker settings
Artifacts/VirdeeKit.xcframework   the shipped binary (committed)
Example/                          Virdee's native example + the VirdeeKit facade
  ios/VirdeeKit/                  VirdeeService, VirdeeServiceImpl, VirdeeRuntime,
                                  VirdeeFlowBridge
  index.js                        registers VirdeeController / VirdeeClearIDV /
                                  VirdeeMobileKey — keep in sync with VirdeeFlowBridge
Scripts/build-xcframework.sh
```

The `.xcframework` is committed rather than published as a release asset. For a
**private** repo that matters: `binaryTarget(url:checksum:)` makes SwiftPM fetch a zip
over HTTP and authenticate, which needs `.netrc` on every machine and on CI. Keeping
the binary in the package repo reduces all of that to plain git access.

## Rebuilding the framework

Needed when the Virdee SDK, the JS screens, or the Swift facade change.

On a machine that has never built this before, start with:

```bash
bash Scripts/bootstrap.sh --check    # verify prerequisites, change nothing
bash Scripts/bootstrap.sh            # ... then install dependencies
bash Scripts/bootstrap.sh --build    # ... and build the xcframework
```

`bootstrap.sh` checks Xcode, Node 18+, Yarn 4 via corepack, CocoaPods, registry
access and free disk **before** starting a build that runs for hours. Each check
exists because it went wrong once; the failure messages carry the fix.

The equivalent by hand:

```bash
cd Example && yarn install && cd ..
cd Example/ios && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 RCT_NEW_ARCH_ENABLED=1 pod install && cd ../..
bash Scripts/build-xcframework.sh
```

Commit the regenerated `Artifacts/VirdeeKit.xcframework` and tag a version — SwiftPM
versions are git tags.

The npm token for the private `@virdee-inc` scope goes in `~/.yarnrc.yml`, never in the
repo. Yarn Berry does **not** read `~/.npmrc`, so it has to be configured separately:

```yaml
npmScopes:
  virdee-inc:
    npmRegistryServer: "https://registry.npmjs.org"
    npmAuthToken: "…"
```

A cold build compiles React Native from source and takes **well over an hour per slice**
(device and simulator build separately). That cost is exactly why HRX consumes a binary:
it is paid here, once, not by every developer on every clone.

### Working on the Virdee screens

Open `Example/ios/VirdeeNativeSDKExample.xcworkspace`, run `yarn start`, and use the
`VirdeeNativeSDKExample` app target with normal Metro hot reload. Only that person needs
Node, CocoaPods and a token. Everyone else consumes the binary.

## VirdeeKit is three binaries, not one

`VirdeeKit.framework` links two vendored dynamic frameworks that it does **not** contain:

- `SeosMobileKeysSDK.framework` — from `@virdee-inc/sdk-mobile-key-seos`, under
  `node_modules/.../ios/SEOS_Mobile_Keys_IOS_SDK/{Debug,Release}/`
- `hermes.framework` — from `Example/ios/Pods/hermes-engine/destroot/Library/Frameworks/universal/`

Without them the app aborts the moment it launches:
*Library not loaded: @rpath/SeosMobileKeysSDK.framework/SeosMobileKeysSDK*, then the same
for hermes. Building and linking succeed either way — this only shows at runtime.

> **Not done yet.** `Package.swift` declares one `binaryTarget`. These two were copied into
> the harness by hand to get a test running. Before HRX can consume the package they need
> to be committed under `Artifacts/` and declared as their own binary targets.

## The JS ↔ Swift contract fails silently

React Native native modules do not error when names diverge. If `index.js` calls a
selector the module does not expose, or subscribes to an event name the emitter does not
send, **nothing happens and nothing is logged**. The build stays green.

This is not hypothetical — it shipped once already. `VirdeeRestartEmitter` sent
`"virdee:restart"` while `index.js` listened for `"VirdeeRestart"`, so `refresh()` quietly
did nothing. The event name now lives in a constant next to a comment naming its
counterpart.

After any change to the bridge, check both directions:

```bash
grep -oE "VirdeeFlowBridge\?\.[a-zA-Z]+" Example/index.js | sed 's/.*\.//' | sort -u
grep -oE "RCT_EXTERN_METHOD\([a-zA-Z]+" Example/ios/VirdeeKit/VirdeeFlowBridge.m | sed 's/.*(//' | sort -u
```

The two lists must be identical, and every name must match an `@objc(...)` in
`VirdeeFlowBridge.swift`. Running `.debug` and watching for `[bridge]` entries confirms
the wiring end to end.

## Releasing

SwiftPM versions are git tags; `Package.swift` has no version field.

```bash
# 1. bump the constant BEFORE building — it is compiled into the binary
sed -i '' 's/let version = "0.2.0"/let version = "0.3.0"/' \
  Example/ios/VirdeeKit/VirdeeKitVersion.swift
# 2. rebuild, 3. commit sources and binary together
bash Scripts/build-xcframework.sh
git add -A && git commit -m "VirdeeKit 0.3.0"
# 4. tag (validates), 5. publish
bash Scripts/release.sh 0.3.0 --push
```

`release.sh` refuses to tag unless the artifact is committed, is **newer than the sources
that produce it**, and carries the version being tagged. That middle check is the point:
the `.xcframework` is committed, so a tag can otherwise point at a binary built before the
last source change, and the diff looks perfectly innocent. It compares commit times rather
than mtimes, which do not survive a fresh clone.

Bump minor for a Virdee SDK update even when the facade is unchanged — the binary contains
the whole SDK, so behaviour moves. In HRX: **File → Packages → Update to Latest Package
Versions**, then commit `Package.resolved`.

## Build settings that are load-bearing

Do not "clean these up":

- **`MACH_O_TYPE = mh_dylib`** — VirdeeKit is a *dynamic* framework so `-ObjC` and
  `-force_load` resolve while building it. A static framework would push those into the
  consumer's `Package.swift` as `unsafeFlags`, which SwiftPM forbids for versioned
  dependencies.
- **`BUILD_LIBRARY_FOR_DISTRIBUTION = YES`** on the VirdeeKit *target*, and explicitly `NO`
  on the pods. This gives module stability, so the framework works across Xcode versions.
  **Never pass it on the `xcodebuild` command line** — command-line settings override every
  target, and `NitroModules` (pulled in by the SEOS plugin) cannot emit a `.swiftinterface`
  because of its C++ interop `margelo` namespace:
  `error: no type named 'margelo' in module 'NitroModules'`.
- **`OTHER_LDFLAGS = -ObjC`** — RN registers native modules and ObjC categories through
  `+load`; without it the linker strips them out.
- **`@_implementationOnly import React`** in `VirdeeRuntime.swift` and
  `VirdeeFlowBridge.swift`. A plain `import` is recorded as a *public* dependency of the
  module even though no React type is exposed, and it lands in
  `VirdeeKit.swiftinterface`. The host then cannot compile without React Native on its own
  header search paths:
  `error: Unable to resolve module dependency: 'React' … a dependency of Swift module 'VirdeeKit'`.
  That defeats the entire point of shipping a binary facade, and it is invisible when
  building the framework — only a consumer sees it. Verify after any change:
  `grep '^import' …/VirdeeKit.swiftinterface` must show only Combine, Foundation and UIKit.
- **`-ffile-prefix-map` on the pods (Podfile `post_install`) and `-file-prefix-map` on
  VirdeeKit**, plus `SWIFT_SERIALIZE_DEBUGGING_OPTIONS = NO`. Source paths otherwise end up
  inside the committed artifact, exposing the build machine's directory layout and whoever
  built it. Three things to know:
  - It must be the **`file`** variant, not `debug`. folly and React-Fabric bake `__FILE__`
    into assertion strings, which land in `__TEXT`, not in debug info.
    `-fdebug-prefix-map` does not touch macros, so paths survive it.
  - **`strip -S` does not help either** — same reason; the strings are not debug symbols.
  - Map both `/private/tmp…` and `/tmp…`: macOS reaches the same directory through a
    symlink and clang records whichever form it was handed.

  Verify after a rebuild — the count must be zero:
  ```bash
  strings Artifacts/VirdeeKit.xcframework/ios-arm64/VirdeeKit.framework/VirdeeKit \
    | grep -c "/Users/\|/private/tmp"
  ```
  The build script also deletes `*.abi.json` from the archives, which embed paths too.
- **Signing differs between the framework and the app**, and getting it backwards costs
  a full rebuild:
  - The **xcframework** is built *unsigned* (`CODE_SIGNING_ALLOWED = NO`). That is
    standard for binary distribution — whoever embeds it signs it. Ad-hoc
    (`CODE_SIGN_IDENTITY = "-"`) is **not** an option: the device SDK rejects it with
    *Ad Hoc code signing is not allowed with SDK 'iOS 26.x'*.
  - The **app** that embeds it must sign normally. Building the harness with
    `CODE_SIGNING_ALLOWED=NO` leaves the SEOS plugin's vendored dynamic
    `SeosMobileKeysSDK.framework` unsigned, and it aborts at launch with
    *Library not loaded: @rpath/SeosMobileKeysSDK.framework/SeosMobileKeysSDK*.

## Toolchain notes

| Problem | Cause | Handled by |
|---|---|---|
| `fmt` fails: *call to consteval function ... is not a constant expression* | RN ships fmt 11.0.2, which Xcode 26's clang rejects | Virdee's `post_install` hook in `Example/ios/Podfile` forces `FMT_USE_CONSTEVAL 0`. Keep it. |
| CocoaPods: *Unicode Normalization not appropriate for ASCII-8BIT* | macOS system Ruby 2.6 with no UTF-8 locale | `LANG`/`LC_ALL` on the `pod install` line |
| CocoaPods resolves stale pods after a Podfile change | cached `Pods/Local Podspecs` | delete `Pods/` and `Podfile.lock`, then reinstall |

Virdee target **Xcode 16.x**; this repo builds under Xcode 26 as well. `react-native-screens`
is pinned to exactly 4.10.0 by Virdee — do not widen it; 4.26 breaks RN 0.79 codegen.

Virdee's zip arrives with `IPHONEOS_DEPLOYMENT_TARGET = 26.2` (an Xcode 26 artifact,
despite their README saying 16.2+). This repo pins **17.0** to match HRX.

## What has actually been verified

- The framework builds, and a **plain SwiftUI app with no `import React` anywhere**
  consumes it, launches, boots the React Native runtime and reaches Virdee's servers.
  That is the whole premise of this package, and it holds.
- `Example/` is that app. It is not a decorative sample — it is the only thing proving
  the facade works from the outside.

## Open items

Known incomplete:

- **`Package.swift` ships one binary target, but three are needed** — see
  "VirdeeKit is three binaries, not one". Until then a consumer crashes at launch.

Blocked on Virdee:

1. **A working `accessToken`.** With the credentials tried so far the SDK gets
   `Context creation failed: Unauthorized`, wrapped by Virdee in an HTTP 500 rather than a
   401. Worth asking them (a) whose key is supposed to sign the token — the docs say
   Virdee's API issues it and the HRX backend only relays — and (b) to return 401 for an
   auth failure. Their `x-request-id` response header identifies the request in their logs.
2. Which lock vendor do the properties use? The example bundles SEOS
   (`@virdee-inc/sdk-mobile-key-seos`); Dormakaba and SALTO are separate packages and
   would change which vendored xcframework ships here.
3. Can `VirdeeSDK.initWithReservation({ env, locationId, confirmationCode, apiKey })`
   replace server-issued tokens, and what scope is that `apiKey`? If it is tenant-level
   it cannot live on the client.

Blocked internally:

- The HRX backend must issue `accessGrantId` / `accessToken` per reservation. Note that
  `refreshToken` is not wired anywhere: `VirdeeController` takes only `accessGrantId`,
  `accessToken` and `env`, so a session currently dies when the access token expires.
- `SceneDelegate` routing for `virdee-sdk://` alongside the existing `DeeplinkService`.

Not yet verified:

- **No flow has run end to end** — initialisation has never succeeded, so requirements,
  CLEAR ID verification and the key have all gone untested.
- **The digital key has never been exercised.** SEOS BLE does not work in the simulator —
  it needs a physical device.
- The framework has not been consumed from HRX itself, only from the harness here.
- Only Debug has been run. The Release path — JS bundle read from inside the framework
  rather than from Metro — is untested.
