/**
 * React Native entry for the Virdee Native SDK Example.
 *
 * The host apps (iOS SwiftUI / Android Kotlin) stay fully native. React Native
 * is embedded ON DEMAND: the native side mounts one of the surfaces registered
 * below and the native side decides where/when to present them.
 *
 * Surfaces
 * --------
 *  • VirdeeController  — hidden/headless. Initializes the SDK for a specific
 *    AccessGrant (constants passed from native via initialProperties), recovers
 *    the AccessGrant, reads its requirements, then signals native intent through
 *    the VirdeeFlowBridge native module:
 *        - always                     → VirdeeFlowBridge.setRequirements(summary)
 *          (native renders the current requirement status on the page)
 *        - ID_VERIFICATION required   → VirdeeFlowBridge.showVerifyIdButton(agId)
 *          (native reveals a "VERIFY YOUR ID" button; CLEAR ID is only presented
 *           when the user taps it — it is NOT opened automatically)
 *        - all requirements COMPLETED → VirdeeFlowBridge.showMobileKeyButton()
 *  • VirdeeClearIDV    — the CLEAR ID verification UI (sdk-core orchestrator +
 *    CLEAR vendor). onClose → closeClearIDV; onComplete ("process ready") →
 *    closeClearIDV + showMobileKeyButton.
 *  • VirdeeMobileKey   — the SEOS mobile key UI. onClose/onCancel → closeMobileKey.
 *
 * The JS never presents anything itself — native owns all containers/modals.
 */
import React, { useCallback, useEffect, useRef } from 'react';
import {
  AppRegistry,
  NativeModules,
  NativeEventEmitter,
  LogBox,
} from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import {
  VirdeeSDK,
  IDVerification,
  useAccessGrant,
} from '@virdee-inc/sdk-core';
import { MobileKey, useMobileKey } from '@virdee-inc/sdk-mobile-key-seos';
import { ClearIDVerification } from '@virdee-inc/sdk-idv-clear';

// RedBox can't present in the transparent overlay windows the native side uses.
LogBox.ignoreLogs([/Attempt to present/, /topSvgLayout/]);

// -----------------------------------------------------------------------------
// Native bridge (implemented in Swift `VirdeeFlowBridge` / Kotlin `VirdeeFlowBridge`)
// -----------------------------------------------------------------------------

const { VirdeeFlowBridge } = NativeModules;

// Normalize any SDK error into a plain, JSON-serializable object the native
// bridge can carry (RN turns this into an NSDictionary / ReadableMap).
const toPayload = (err) => {
  if (!err) return {};
  if (typeof err === 'string') return { message: err };
  const { code, message, name, vendor } = err;
  return {
    code: code ?? name ?? 'UNKNOWN',
    message: message ?? String(err),
    ...(vendor ? { vendor } : {}),
  };
};

// Mirror the JS console into VirdeeKit's logger. Without this the controller is
// mute: it runs in a 1x1 transparent surface, so React Native's redbox never
// appears, and a release build has no Metro to print to. VirdeeKit's own log
// level decides whether any of it is shown.
const forward = (level, args) => {
  try {
    const text = args
      .map((a) => {
        if (typeof a === 'string') return a;
        if (a instanceof Error) return `${a.name}: ${a.message}`;
        try {
          return JSON.stringify(a);
        } catch {
          return String(a);
        }
      })
      .join(' ');
    VirdeeFlowBridge?.log?.(level, text);
  } catch {
    // Logging must never break the flow it is reporting on.
  }
};

['log', 'info', 'warn', 'error'].forEach((name) => {
  const original = console[name]?.bind(console);
  console[name] = (...args) => {
    original?.(...args);
    forward(name === 'log' || name === 'info' ? 'debug' : name, args);
  };
});

const bridge = {
  // The SDK could not start at all — bad credentials, no network, dead grant.
  //   payload: { code, message, vendor? }
  failedToStart: (payload) => {
    console.log('[VirdeeFlow] → native.failedToStart', payload);
    VirdeeFlowBridge?.failedToStart?.(payload ?? {});
  },
  // Report the current requirement status so native can render it on the page.
  //   summary: { requirements: [{ type, status }], idvRequired, allComplete }
  setRequirements: (summary) => {
    console.log('[VirdeeFlow] → native.setRequirements', summary);
    VirdeeFlowBridge?.setRequirements?.(summary);
  },
  // Reveal the native "VERIFY YOUR ID" button (instead of opening CLEAR ID
  // immediately). Native presents the CLEAR ID overlay only when it is tapped.
  showVerifyIdButton: (accessGrantId) => {
    console.log('[VirdeeFlow] → native.showVerifyIdButton', accessGrantId);
    VirdeeFlowBridge?.showVerifyIdButton?.(accessGrantId);
  },
  showClearIDV: (accessGrantId) => {
    console.log('[VirdeeFlow] → native.showClearIDV', accessGrantId);
    VirdeeFlowBridge?.showClearIDV?.(accessGrantId);
  },
  closeClearIDV: () => {
    console.log('[VirdeeFlow] → native.closeClearIDV');
    VirdeeFlowBridge?.closeClearIDV?.();
  },
  showMobileKeyButton: () => {
    console.log('[VirdeeFlow] → native.showMobileKeyButton');
    VirdeeFlowBridge?.showMobileKeyButton?.();
  },
  closeMobileKey: () => {
    console.log('[VirdeeFlow] → native.closeMobileKey');
    VirdeeFlowBridge?.closeMobileKey?.();
  },
  // Single generic channel for IDV / Mobile Key lifecycle callbacks. The native
  // side (VirdeeFlowBridge.onVirdeeEvent) decides how to react per flow+event.
  //   flow:  'idv' | 'mobileKey'
  //   event: 'success' | 'error' | 'close' | 'cancel' | 'event'
  emit: (flow, event, payload) => {
    console.log(
      `[VirdeeFlow] → native.onVirdeeEvent ${flow}.${event}`,
      payload ?? ''
    );
    VirdeeFlowBridge?.onVirdeeEvent?.(flow, event, payload ?? {});
  },
  // Headless mobile key: one snapshot of useMobileKey's state per change, for a
  // host that draws the screen itself. The VirdeeMobileKey surface does not use
  // this — it ships Virdee's own UI and reports through `emit` instead.
  mobileKeyState: (state) => {
    VirdeeFlowBridge?.mobileKeyState?.(state ?? {});
  },
};

const IDV_TYPE = 'ID_VERIFICATION';
const STATUS_COMPLETED = 'COMPLETED';

// -----------------------------------------------------------------------------
// Surface 1: Controller (hidden) — inits the SDK and drives the flow
// -----------------------------------------------------------------------------

function VirdeeController({ accessGrantId, accessToken, refreshToken, env }) {
  const { fetchFullDetailsById } = useAccessGrant();
  const startedRef = useRef(false);

  // Read the (possibly refreshed) requirements and tell native what to present.
  // Safe to call repeatedly — native decides what to show from these signals.
  const evaluateAndSignal = useCallback(
    (grant) => {
      if (!grant) return;

      const requirements = grant.requirements ?? [];
      const idv = requirements.find((r) => r.type === IDV_TYPE);
      const idvRequired = !!idv && idv.status !== STATUS_COMPLETED;
      // No requirements at all, or every one satisfied → key is ready. ([].every
      // is true, so the empty case flows straight to the mobile-key button.)
      const allComplete = requirements.every(
        (r) => r.status === STATUS_COMPLETED
      );

      console.log('[VirdeeController] requirements', {
        count: requirements.length,
        idvRequired,
        allComplete,
      });

      // Always report the current requirement status to native for display.
      bridge.setRequirements({
        requirements: requirements.map((r) => ({
          type: r.type,
          status: r.status,
        })),
        idvRequired,
        allComplete,
      });

      // The mobile key and ID verification are independent — once the SDK is
      // initialized the key is always available, so reveal its button
      // regardless of requirement status.
      bridge.showMobileKeyButton();

      if (idvRequired) {
        // Don't open CLEAR ID immediately — reveal the native "VERIFY YOUR ID"
        // button and let the user start verification when they're ready.
        bridge.showVerifyIdButton(accessGrantId);
      }
    },
    [accessGrantId]
  );

  // Init once for the specific AccessGrant, then recover it + its requirements
  // and signal native.
  useEffect(() => {
    if (startedRef.current) return;
    startedRef.current = true;

    (async () => {
      try {
        console.log('[VirdeeController] init', { accessGrantId, env });
        if (VirdeeSDK.isInitialized()) {
          await VirdeeSDK.reset();
        }
        await VirdeeSDK.init({
          env: env || 'production',
          accessGrantId,
          accessToken,
          ...(refreshToken ? { refreshToken } : {}),
        });
        const grant = await fetchFullDetailsById(accessGrantId);
        console.log('[VirdeeController] AccessGrant recovered');
        evaluateAndSignal(grant);
      } catch (error) {
        console.error('[VirdeeController] init failed:', error);
        // Tell native, or the failure is invisible: this surface is 1x1 and
        // transparent, so nothing renders and no redbox appears. Without this
        // the host sits forever on "checking requirements" with no event.
        bridge.failedToStart(toPayload(error));
      }
    })();
  }, [
    accessGrantId,
    accessToken,
    env,
    fetchFullDetailsById,
    evaluateAndSignal,
  ]);

  // Re-arm on demand: when native taps "Get your key" again (e.g. after an IDV
  // cancel) it fires `VirdeeRestart`. Re-read requirements on the LIVE surface
  // (no SDK reset/init) and re-signal — this keeps the RN host alive instead of
  // rebuilding it, which would hang on "Checking requirements…".
  useEffect(() => {
    const emitterModule = NativeModules.VirdeeRestartEmitter;
    if (!emitterModule) return undefined;

    const emitter = new NativeEventEmitter(emitterModule);
    const sub = emitter.addListener('VirdeeRestart', async () => {
      try {
        console.log('[VirdeeController] restart → re-checking requirements');
        const grant = await fetchFullDetailsById(accessGrantId);
        evaluateAndSignal(grant);
      } catch (error) {
        console.error('[VirdeeController] restart failed:', error);
      }
    });
    return () => sub.remove();
  }, [accessGrantId, fetchFullDetailsById, evaluateAndSignal]);

  // Headless — the native host may show its own loading UI meanwhile.
  return null;
}

// -----------------------------------------------------------------------------
// Surface 2: CLEAR ID verification (native-owned modal)
// -----------------------------------------------------------------------------

const IDV_VENDORS = { CLEAR: ClearIDVerification };

function VirdeeClearIDV({ accessGrantId }) {
  // The IDV orchestrator has no onCancel — its only terminal signal is onClose
  // (fires on close/swipe OR post-success Continue). A close WITHOUT a prior
  // completion is a user cancel; native uses that to reset the flow.
  const completedRef = useRef(false);

  return (
    <SafeAreaProvider>
      <IDVerification
        vendors={IDV_VENDORS}
        onComplete={(results) => {
          console.log('[VirdeeClearIDV] onComplete', results);
          completedRef.current = true;
          bridge.emit('idv', 'success', { results });
          // Reveal the native "USE MOBILE KEY" button while the SDK success
          // screen stays up; teardown happens on the terminal onClose.
          bridge.showMobileKeyButton();
        }}
        onError={(error) => {
          console.log('[VirdeeClearIDV] onError', error);
          bridge.emit('idv', 'error', toPayload(error));
        }}
        onClose={() => {
          const event = completedRef.current ? 'close' : 'cancel';
          console.log('[VirdeeClearIDV] onClose', event, accessGrantId);
          bridge.emit('idv', event, { accessGrantId });
          bridge.closeClearIDV();
        }}
      />
    </SafeAreaProvider>
  );
}

// -----------------------------------------------------------------------------
// Surface 3: SEOS mobile key (native-owned modal)
// -----------------------------------------------------------------------------

function VirdeeMobileKey({ accessGrantId }) {
  return (
    <SafeAreaProvider>
      <MobileKey
        accessGrantId={accessGrantId}
        onSuccess={() => {
          console.log('[VirdeeMobileKey] onSuccess');
          bridge.emit('mobileKey', 'success', { accessGrantId });
        }}
        onError={(error) => {
          console.log('[VirdeeMobileKey] onError', error);
          bridge.emit('mobileKey', 'error', toPayload(error));
        }}
        onEvent={(event) => {
          console.log('[VirdeeMobileKey] onEvent', event);
          bridge.emit('mobileKey', 'event', { event });
        }}
        onClose={() => {
          console.log('[VirdeeMobileKey] onClose', accessGrantId);
          bridge.emit('mobileKey', 'close', { accessGrantId });
          bridge.closeMobileKey();
        }}
        onCancel={() => {
          // Unlock cancelled → SEOS returns to 'ready'. Keep the overlay open so
          // the user can retry; only report the event to native.
          console.log('[VirdeeMobileKey] onCancel', accessGrantId);
          bridge.emit('mobileKey', 'cancel', { accessGrantId });
        }}
      />
    </SafeAreaProvider>
  );
}

// -----------------------------------------------------------------------------
// Surface 4: SEOS mobile key, headless — the host draws its own screen
// -----------------------------------------------------------------------------

/**
 * Same lifecycle as VirdeeMobileKey, with none of the UI. Mounted 1x1 and
 * transparent; every state change is pushed to native, and native drives it back
 * through the `VirdeeMobileKeyCommand` event.
 *
 * Virdee require that only ONE useMobileKey consumer is mounted per access grant,
 * so VirdeeServiceImpl refuses to run this and the VirdeeMobileKey overlay at the
 * same time.
 */
function VirdeeMobileKeyHeadless({ accessGrantId, autoActivate, unlockTimeout }) {
  // The hook's state carries `errorMessage` but not the code, and the host needs
  // the code to tell "Bluetooth is off" from "permission denied" — different
  // screens in the design. onError is the only place it appears.
  const errorCodeRef = useRef(null);

  const key = useMobileKey({
    accessGrantId,
    autoInitialize: true,
    autoActivate: !!autoActivate,
    unlockTimeoutInSeconds: unlockTimeout ?? 10,
    onSuccess: () => {
      errorCodeRef.current = null;
      console.log('[VirdeeMobileKeyHeadless] onSuccess');
    },
    onError: (error) => {
      errorCodeRef.current = error?.type ?? error?.code ?? 'UNKNOWN';
      console.log('[VirdeeMobileKeyHeadless] onError', error);
    },
  });

  const {
    status,
    isRecovering,
    errorMessage,
    errorCount,
    statusMessage,
    unlockRemainingSeconds,
    unlockProgress,
    resource,
  } = key;

  // One snapshot per change. Sent on mount too, so the host has something to
  // render before the first transition.
  useEffect(() => {
    bridge.mobileKeyState({
      status,
      isRecovering: !!isRecovering,
      errorCode: status === 'error' ? errorCodeRef.current : null,
      errorMessage: errorMessage ?? null,
      errorCount: errorCount ?? 0,
      statusMessage: statusMessage ?? null,
      unlockRemainingSeconds: unlockRemainingSeconds ?? 0,
      unlockProgress: unlockProgress ?? 0,
      // `floor` is wired through although the backend does not populate it yet —
      // cheaper than changing the contract again once it does.
      roomName: resource?.name ?? null,
      floor: resource?.floor ?? null,
    });
  }, [
    status,
    isRecovering,
    errorMessage,
    errorCount,
    statusMessage,
    unlockRemainingSeconds,
    unlockProgress,
    resource,
  ]);

  // Native -> JS commands. The event name must match VirdeeCommandEmitter in
  // VirdeeFlowBridge.swift; a mismatch here fails silently.
  useEffect(() => {
    const emitterModule = NativeModules.VirdeeRestartEmitter;
    if (!emitterModule) return undefined;

    const emitter = new NativeEventEmitter(emitterModule);
    const sub = emitter.addListener('VirdeeMobileKeyCommand', ({ command }) => {
      console.log('[VirdeeMobileKeyHeadless] command', command);
      switch (command) {
        case 'openLock':     key.openLock(); break;
        case 'cancelUnlock': key.cancelUnlock(); break;
        case 'dismissError': key.resetAfterError(); break;
        // One "Try Again" button, two failures behind it. Provisioning can fail
        // before a key exists (PLUGIN_INIT_FAILED / "Endpoint setup timed out"),
        // and retryUnlock() would retry an unlock that never started.
        case 'retry':
          if (key.isReady) {
            key.retryUnlock();
          } else {
            key.initialize();
          }
          break;
        default:
          console.warn('[VirdeeMobileKeyHeadless] unknown command', command);
      }
    });
    return () => sub.remove();
  }, [key]);

  return null;
}

// -----------------------------------------------------------------------------
// Registration — native mounts these by name, on demand.
// -----------------------------------------------------------------------------

AppRegistry.registerComponent('VirdeeController', () => VirdeeController);
AppRegistry.registerComponent('VirdeeClearIDV', () => VirdeeClearIDV);
AppRegistry.registerComponent('VirdeeMobileKey', () => VirdeeMobileKey);
AppRegistry.registerComponent('VirdeeMobileKeyHeadless', () => VirdeeMobileKeyHeadless);
