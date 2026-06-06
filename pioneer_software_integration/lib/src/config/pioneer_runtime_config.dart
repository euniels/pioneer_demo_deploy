class PioneerRuntimeConfig {
  static const bool showMockData = bool.fromEnvironment(
    'PIONEER_SHOW_MOCK_DATA',
    defaultValue: true,
  );
}
