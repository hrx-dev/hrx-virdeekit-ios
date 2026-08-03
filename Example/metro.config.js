const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

/**
 * Metro configuration.
 * https://reactnative.dev/docs/metro
 *
 * Standard configuration for consuming the published Virdee SDK packages from
 * node_modules. The only non-default option is `unstable_enablePackageExports`,
 * required so subpath imports like `@virdee-inc/sdk-core/plugin` resolve on
 * React Native 0.79.
 *
 * @type {import('@react-native/metro-config').MetroConfig}
 */
const config = {
  resolver: {
    unstable_enablePackageExports: true,
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
