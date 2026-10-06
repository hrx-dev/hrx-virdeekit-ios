# Changelog

Versions are git tags; SwiftPM resolves by tag. See README for the release procedure.

## 0.6.0

### The JS runtime is never released

0.5.0 made `stop()` release `RCTReactNativeFactory` after a short delay instead of
immediately. That stopped the crash at teardown and moved it to the next entry into the
flow. Two signatures in production (1.0.3/124):

```
nitro::install → HybridObjectPrototype::createPrototype
               → HermesRuntimeImpl::createFunctionFromHostFunction

-[RCTNetworking prioritizedHandlers] → +[NSArray arrayWithObjects:count:]   (nil handler)
  concurrently with -[RCTInstance invalidate] → ~HermesRuntimeImpl on the JS thread
```

`react-native-nitro-modules` keeps process-global static caches keyed by the raw
`jsi::Runtime*` — `PropNameIDCache`, `CommonGlobals`, `Prototype` — and clears none of
them, so a runtime allocated at a recycled address inherits references into a freed one.
The second crash is plainer: in-flight requests outlive `invalidate`.

Both have one cause: destroying and recreating the runtime in a live process. Virdee
confirmed (Oct 2026) that the SDK is meant to live for the whole app, that rebooting the
runtime is expensive and discouraged, and that there is no separate "end session" API.

So `VirdeeRuntime` has no `shutdown()` any more. `stop()` keeps the ordering introduced
in 0.5.0 — detach the bridge, unmount every surface, clear state — and leaves the runtime
running. A later `start(session:)` mounts a fresh controller; `index.js` then runs
`if (isInitialized()) await reset()` before `init()` with the new credentials, which is
the sequence Virdee prescribe for re-entry (the `reset()` touches async storage, hence
the await).

This is **not** a return to 0.4.0: that crash was caused by releasing the factory, and
there is no release left to make.

### `startTimeout`

```swift
VirdeeConfiguration(logLevel: .error, startTimeout: 20)   // 0 disables
```

`start(session:)` arms a watchdog; the first `.requirementsLoaded` or `.failedToStart`
disarms it. If neither arrives, the kit publishes `.failedToStart` itself.

Re-entry now re-initialises inside a warm runtime, and a `reset()` that never returns
throws nothing — the host would sit on a spinner with no event at all. This turns that
into one it already handles. The new parameter sits between the two existing ones, so
calls written against 0.5.x keep compiling.

### Upgrading

No API removed, no event added. Hosts that already pair `start`/`stop` need no change.
Worth re-checking: nothing may assume `stop()` frees memory or resets JS state, and
`.failedToStart` can now arrive from the timeout — later, and without an SDK error
behind it.

### Not verified

Re-entering a flow twice with different reservations — the case that crashes today — has
not been run against this build. It needs live credentials, and the mobile key needs a
physical device for BLE.

## 0.5.1

Fixes a TestFlight upload rejection. `VirdeeKit.framework`'s `Info.plist` had no
`CFBundleShortVersionString`, and App Store Connect validates every embedded framework:

```
ERROR 90057: The bundle 'Payload/Hard Rock.app/Frameworks/VirdeeKit.framework'
is missing plist key ... CFBundleShortVersionString
```

`GENERATE_INFOPLIST_FILE` only emits that key when `MARKETING_VERSION` is set, and it
was never set on the framework target — only on the example app. `CFBundleVersion` was
present, which is why nothing looked wrong locally.

Nothing in a build or an archive fails on this; it surfaces only at upload, after the
whole pipeline has run. `release.sh` now refuses to tag unless both keys are present in
both slices and `CFBundleShortVersionString` matches the tag.

No API change. All three shipped frameworks were checked: `SeosMobileKeysSDK` (10.0.2)
and `hermes` (0.12.0) already carried both keys.

## 0.5.0

### `stop()` is safe to call from an event handler

Calling `stop()` shortly after a flow ended crashed the host:

```
*** -[__NSPlaceholderArray initWithObjects:count:]: attempt to insert nil object
    from objects[3]
Scheduler::~Scheduler() / UIManagerBinding::~UIManagerBinding() / UIManager::~UIManager()
```

Reproducible after a successful ID verification, after a mobile-key error, and after
closing the mobile-key screen. Deferring the call with `DispatchQueue.main.async` did
not help: React Native keeps unmounting its tree across several run-loop turns, and
`stop()` released `RCTReactNativeFactory` in the middle of it.

`stop()` now runs in three ordered phases:

1. Detach the `VirdeeFlowBridge` sinks, so nothing further arrives while state is
   being cleared — this is what makes a call from inside an event handler safe.
2. Unmount the surfaces. Dropping the root views is what *starts* React Native's
   teardown, so it has to precede the runtime going away.
3. Release the runtime after React Native has drained its unmount work.

It is now idempotent: a second `stop()`, or one without a preceding `start(session:)`,
does nothing. `start(session:)` called before the runtime has been released cancels the
release and reuses the warm runtime, which also makes a repeat flow start faster.

The bridge sinks are static, so the service that wired last owns them; only that owner
detaches. Previously they were wired in `init`, which let a second service silently
unhook the first — they are now wired in `start(session:)`.

**No events are published as a result of `stop()`.**

### Two new `VirdeeEvent` cases

```swift
case idVerificationDismissed
case mobileKeyDismissed
```

Both are sent **after** the overlay window has been hidden and released, and mean
"nothing further will arrive for this flow". `idVerificationDismissed` always follows
an `.idVerification(_)` outcome describing how it ended; the dismissal only reports
that the screen is down.

`mobileKeyDismissed` closes a real gap: ID verification was implicitly followed by
`.mobileKeyAvailable`, but the mobile key flow had no terminal signal at all, so a host
could not tell when the kit was finished with it.

`VirdeeEvent` is a non-frozen enum in a binary module and hosts switch over it with a
`default`, so existing code keeps compiling. Hosts that want the new signals must add
the cases.

### Upgrading

No API removed. A host that calls `stop()` late, to work around the crash, can move the
call back to the terminal event — typically `mobileKeyDismissed` or
`idVerificationDismissed`.

### Not verified

Neither flow has been run end to end against these changes: the last live credentials
expired, and the mobile key needs a physical device for BLE. The reported
`PLUGIN_INIT_FAILED` / "Endpoint setup timed out" is untouched by this release — it is a
separate issue, though it is a good test case for `stop()` on the error path.

## 0.4.0

Virdee SDK bumped: sdk-core 4.0.1 → 4.2.0, sdk-idv-clear 1.0.1 → 1.2.0,
sdk-mobile-key-seos 1.0.1 → 1.1.1. React Native stayed at 0.79.4.

## 0.3.1

Fixed a `Package.swift` no consumer could import: the wrapper target re-exported a
module name that does not exist (`VirdeeKitBinary` is a SwiftPM label, while the module
inside the xcframework is `VirdeeKit`). Every consumer got "Cannot find
'VirdeeConfiguration' in scope". `Scripts/verify-package.sh` now builds a throwaway
consumer, and `release.sh` runs it before tagging.

## 0.3.0

Ships three binary targets instead of one: `VirdeeKit` links `SeosMobileKeysSDK` and
`hermes` dynamically but contains neither, so an app built against the previous release
aborted at launch with "Library not loaded".

## 0.2.0

Configurable logging (`VirdeeLogLevel`, `VirdeeConfiguration`, optional `logHandler`),
with the SDK's own JavaScript console forwarded to the Xcode console and JWTs redacted.

## 0.1.0

First proof of concept: React Native, `node_modules`, CocoaPods and the JS bundle
isolated inside a prebuilt `VirdeeKit.xcframework` behind the `VirdeeService` facade.
