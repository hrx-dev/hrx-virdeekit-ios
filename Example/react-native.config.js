/**
 * React Native CLI configuration for the iOS example app.
 *
 * Autolinking discovers the Virdee native modules from node_modules:
 *   - @virdee-inc/sdk-mobile-key-seos  -> SeosApiPackage
 *   - @virdee-inc/sdk-idv-clear        -> ClearBridgePackage
 * @virdee-inc/sdk-core has no native module, so nothing to link there.
 *
 * VirdeeKit is iOS-only; Virdee's Android host was dropped from this repo.
 */
module.exports = {
  project: {
    ios: {},
  },
};
