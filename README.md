# VirdeeKit

Swift package that wraps the Virdee guest-experience SDK behind a native interface.

Virdee ship **only** a React Native SDK. HRX is a native Swift app on SwiftPM with no
CocoaPods and no Node toolchain. VirdeeKit exists so that stays true: React Native,
`node_modules`, CocoaPods and the JS bundle all live inside a prebuilt
`VirdeeKit.xcframework`, and HRX consumes it as an ordinary SwiftPM dependency.

Built on Virdee's own native host example, which they supply on request — the public
docs pages for native integration are published empty.

> **Status: proof of concept, initialising against live credentials.** The SDK boots,
> reports requirements, and both flows present and report their outcome back through
> the facade. Nothing has been driven to *completion* yet: ID verification stops at the
> CLEAR sign-in, and the digital key needs a physical device.

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
        case .mobileKeyDismissed, .idVerificationDismissed:
            virdee.stop()                         // safe from inside the handler
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

- **`window` on the `AppDelegate`, even in a scene-based app.** React Native reads
  `UIApplication.shared.delegate.window` in `RCTWindowSafeAreaProxy`, `RCTDeviceInfo`,
  `RCTLogBoxView` and `RCTProfile`. A scene-based host keeps its window in the
  `SceneDelegate`, so the first Virdee surface to mount kills the app with
  `-[AppDelegate window]: unrecognized selector`. Declare it computed, returning the
  foreground scene's key window — a stored `nil` answers the selector but reports zero
  safe-area insets, and Virdee's screens then lay out under the notch. The harness cannot
  catch this: it is a SwiftUI app with no `AppDelegate` and no scene manifest.

- `Info.plist`: `NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, `NSCameraUsageDescription`, and
  `NSAppTransportSecurity` with `NSAllowsArbitraryLoads = false`
- URL scheme `virdee-sdk`, declared in `CFBundleURLTypes`. CLEAR redirects to
  `virdee-sdk://clear`, but `ASWebAuthenticationSession` captures that itself — there is
  **no** `openURL` handler to write and nothing for `SceneDelegate` to route. Declaring
  the scheme still matters: from iOS 17.4 the session fails if another installed app
  claims it.
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
5. When the surface goes away, `.idVerificationDismissed` / `.mobileKeyDismissed` are
   published **after** the overlay window is hidden and released. They mean "nothing
   further will arrive for this flow" and are the right place to call `stop()`.

All surfaces share one JS runtime, so the `VirdeeSDK` singleton and its access-grant
store are shared. `refresh()` re-arms the existing controller; it never rebuilds it,
because rebuilding re-runs `VirdeeSDK.reset()/init()` and hangs on "Checking requirements…".

### Stopping

`stop()` may be called from inside an `events` handler, including the handler for the
event that ended the flow. It detaches the bridge first, then unmounts every surface.
It is idempotent and publishes no events.

**The JS runtime is never released.** Virdee confirmed the SDK is meant to live for the
whole app, and tearing React Native down and building it again crashed in production two
different ways — nitro's process-global caches are keyed by the raw `jsi::Runtime*` and
never cleared, and in-flight requests outlive `RCTInstance invalidate`. See CHANGELOG
0.6.0. A later `start(session:)` reuses the warm runtime, mounts a fresh controller, and
the SDK re-initialises itself with `reset()` then `init()`.

The cost is one runtime held for the lifetime of any process that opened a Virdee flow.
That is the supported shape, not a workaround.

## Driving the key yourself

`presentMobileKey()` shows Virdee's own screen. For a screen of your own, take a
controller instead — same SDK, same BLE, no Virdee UI at all:

```swift
let key = virdee.makeMobileKeyController(unlockTimeout: 10)

key.state
    .receive(on: DispatchQueue.main)
    .sink { [weak self] state in
        switch state.phase {
        case .initializing, .provisioningKey:
            self?.showPreparing(state.statusMessage)
        case .unlocking:
            self?.showHoldNearReader(secondsLeft: state.unlockRemainingSeconds)
        case .success:
            self?.showUnlocked()
        case .error:
            self?.showError(retryTitle: "Try Again")
        default:
            break
        }

        // Bluetooth has its own screens and must be checked before errorMessage.
        switch state.bluetooth {
        case .off:              self?.showBluetoothOff()               // no button
        case .permissionDenied: self?.showOpenSettings()               // → openSettingsURLString
        default:                break
        }

        self?.card.room = state.roomName
    }
    .store(in: &cancellables)

key.start()            // unlock begins as soon as the key is ready
// key.start(autoActivate: false) + key.openLock() to drive it from a button
```

`retry()` backs the "Try Again" button, `cancelUnlock()` returns to `.ready` without an
error, and `stop()` unmounts when the screen goes away. Opening Settings is the host's
call — VirdeeKit does not reach for `UIApplication`.

**The two flows are mutually exclusive.** Virdee allow one consumer of the key per
access grant, so starting a controller while their screen is presented — or the reverse
— is refused and logged. Both remain available; just not at once.

`floor` is carried in the state but the backend does not populate it yet, so expect
`nil`. It is wired through so the contract does not have to change when it does.

### When the SDK goes quiet

Re-entry re-initialises inside a warm runtime, and `reset()` touches async storage. If it
never returns, nothing throws — so `start(session:)` arms a watchdog and publishes
`.failedToStart` when neither requirements nor a failure arrive in time:

```swift
VirdeeConfiguration(logLevel: .error, startTimeout: 20)   // seconds; 0 disables
```

## Repo layout

```
Package.swift                     binaryTarget(path:) — no artifact hosting needed
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

All three are committed under `Artifacts/` and declared as separate binary targets. The
product carries all three, so a consumer still writes one `import` and Xcode embeds all
three by itself — no manual copying into the host app.

There is deliberately **no wrapper target**. A `binaryTarget`'s name in `Package.swift` is
only a SwiftPM label; the importable module name comes from the framework inside the
xcframework, which is `VirdeeKit`. A wrapper named `VirdeeKit` collides with that, and
`@_exported import VirdeeKitBinary` cannot resolve — there is no such module. 0.3.0
shipped exactly that and no consumer could compile against it. `Scripts/verify-package.sh`
exists to make that failure impossible to ship again; `release.sh` runs it.

`build-xcframework.sh` re-copies both vendored frameworks from `node_modules` and `Pods`
on every run. They must not drift from the binary that was just linked against them.

Hermes is rebuilt with only the two iOS slices. CocoaPods vendors it with tvOS, Mac
Catalyst and visionOS as well — 72 MB instead of 20 MB for platforms this package does not
support.

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
sed -i '' 's/let version = "0.3.0"/let version = "0.4.0"/' \
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
  the facade works from the outside. Note what it does **not** prove: it compiles
  VirdeeKit from source and never reads `Package.swift`, so it cannot catch a broken
  manifest. `Scripts/verify-package.sh` is the check that does.
- Against live production credentials the SDK initialises, `requirementsLoaded`,
  `mobileKeyAvailable` and `idVerificationRequired` all arrive, `presentIDVerification()`
  reaches CLEAR's sign-in, `presentMobileKey()` mounts the SEOS screen, and closing it
  comes back as `mobileKey(.closed)`. The round trip native → JS → SDK → JS → native holds.

### The harness must not link the shipped artifact

`Example/` builds VirdeeKit from source against CocoaPods, so it must use the **pod's**
hermes, not `Artifacts/hermes.xcframework`. The shipped one is built from a Release
archive and has no debugger, so pointing the harness at it drops every
`inspector_modern` symbol and Debug fails to link with a wall of
`facebook::hermes::inspector_modern::…` undefined symbols that says nothing about the
real cause. The project references
`Pods/hermes-engine/destroot/Library/Frameworks/universal/hermes.xcframework` for that
reason. `Artifacts/` is for consumers of the package only.

## Open items

Blocked on Virdee:

1. **Ask them to return 401, not 500, for an auth failure.** A token the environment
   cannot verify fails during GraphQL context creation and surfaces as
   `HTTP 500 · Context creation failed: Unauthorized` with
   `extensions.code = INTERNAL_SERVER_ERROR`. That reads like an outage on their side and
   cost days here. Their `x-request-id` response header identifies the request in their logs.
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

- **Neither flow has been driven to completion.** ID verification reaches CLEAR's
  `ASWebAuthenticationSession` sign-in and stops there; the key screen mounts and stays on
  "Loading your mobile key…" because SEOS BLE needs a physical device. Everything up to
  those two points works, including the outcome events coming back.
- **Cancelling CLEAR's sign-in sheet killed the app on the simulator.** `EXC_GUARD` /
  `XPC_EXIT_REASON_FAULT`, with a backtrace entirely inside `libxpc` and `BoardServices` —
  no VirdeeKit or React frames. Almost certainly a simulator-only
  `ASWebAuthenticationSession` fault, but confirm on a device before trusting that.
- The framework has not been consumed from HRX itself, only from the harness here.
- Only Debug has been run. The Release path — JS bundle read from inside the framework
  rather than from Metro — is untested.
