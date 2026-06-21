import '../models/telemetry_view_data.dart';

class DemoTelemetryFixtures {
  const DemoTelemetryFixtures._();

  static bool hasColdChainSensor(Map<String, dynamic> vehicle) {
    final explicit = vehicle['hasTemperatureSensor'] == true ||
        vehicle['hasColdChainSensor'] == true;
    final plate = _plate(vehicle);
    return explicit || plate == 'DEMO-TRK-01' || plate == 'DEMO-TRK-02';
  }

  static List<TelemetryReadingViewData> readingsForVehicle(
    Map<String, dynamic> vehicle, {
    double? temperatureOverride,
    List<double> temperatureHistory = const <double>[],
    TelemetryTrend temperatureTrend = TelemetryTrend.stable,
  }) {
    final diagnostics = _map(vehicle['diagnostics']);
    final sensorEquipped = hasColdChainSensor(vehicle);
    final plate = _plate(vehicle);
    final temperature = temperatureOverride ??
        telemetryNumber(
          _map(diagnostics['cargoTemperature'])['value'] ??
              _map(diagnostics['temperature'])['value'] ??
              vehicle['temperatureC'],
        );
    final humidity = telemetryNumber(
      _map(diagnostics['relativeHumidity'])['value'] ?? vehicle['humidity'],
    );
    final fuelRatio = telemetryNumber(
      _map(diagnostics['fuelLevel'])['value'] ?? vehicle['fuelLevelRatio'],
    );
    final fuelPercent = fuelRatio == null
        ? null
        : fuelRatio <= 1
        ? fuelRatio * 100
        : fuelRatio;
    final now = DateTime.now();
    final explicitSource = vehicle['telemetrySource']?.toString().trim() ?? '';
    final source = explicitSource.isNotEmpty
        ? explicitSource
        : plate.startsWith('DEMO-')
        ? 'Demo sensor'
        : 'GeoTab';

    return [
      sensorEquipped
          ? TelemetryReadingViewData(
              key: 'temperature',
              label: 'Cargo temperature',
              value: temperature ?? (plate == 'DEMO-TRK-02' ? 7.4 : 4.4),
              unit: '\u00B0C',
              severity: _temperatureSeverity(
                temperature ?? (plate == 'DEMO-TRK-02' ? 7.4 : 4.4),
              ),
              trend: temperatureTrend,
              availability: TelemetryAvailability.live,
              updatedAt: now,
              safeMin: 2,
              safeMax: 8,
              source: source,
              history: temperatureHistory,
            )
          : TelemetryReadingViewData.notEquipped(
              key: 'temperature',
              label: 'Cargo temperature',
              unit: '\u00B0C',
            ),
      sensorEquipped
          ? TelemetryReadingViewData(
              key: 'humidity',
              label: 'Humidity',
              value: humidity ?? (plate == 'DEMO-TRK-02' ? 57 : 54),
              unit: '%',
              severity: _humiditySeverity(
                humidity ?? (plate == 'DEMO-TRK-02' ? 57 : 54),
              ),
              availability: TelemetryAvailability.live,
              updatedAt: now,
              safeMin: 35,
              safeMax: 65,
              source: source,
            )
          : TelemetryReadingViewData.notEquipped(
              key: 'humidity',
              label: 'Humidity',
              unit: '%',
            ),
      fuelPercent == null
          ? TelemetryReadingViewData.unavailable(
              key: 'fuel',
              label: 'Fuel level',
              unit: '%',
            )
          : TelemetryReadingViewData(
              key: 'fuel',
              label: 'Fuel level',
              value: fuelPercent,
              unit: '%',
              severity: fuelPercent < 20
                  ? TelemetrySeverity.critical
                  : fuelPercent < 35
                  ? TelemetrySeverity.warning
                  : TelemetrySeverity.normal,
              availability: TelemetryAvailability.live,
              updatedAt: now,
              safeMin: 20,
              source: source,
            ),
    ];
  }

  static String _plate(Map<String, dynamic> vehicle) =>
      (vehicle['plate'] ?? vehicle['name'] ?? vehicle['vehicle'] ?? '')
          .toString()
          .trim()
          .toUpperCase();

  static Map<String, dynamic> _map(dynamic value) => value is Map
      ? Map<String, dynamic>.from(value)
      : const <String, dynamic>{};

  static TelemetrySeverity _temperatureSeverity(double value) {
    if (value < 0 || value > 10) return TelemetrySeverity.critical;
    if (value < 2 || value > 8) return TelemetrySeverity.warning;
    return TelemetrySeverity.normal;
  }

  static TelemetrySeverity _humiditySeverity(double value) {
    if (value < 25 || value > 75) return TelemetrySeverity.critical;
    if (value < 35 || value > 65) return TelemetrySeverity.warning;
    return TelemetrySeverity.normal;
  }
}
