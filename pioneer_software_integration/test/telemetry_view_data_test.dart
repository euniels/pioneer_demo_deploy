import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/models/telemetry_view_data.dart';
import 'package:pioneerpath/src/services/demo_telemetry_fixtures.dart';

void main() {
  test('missing telemetry is distinct from a reported zero', () {
    const zero = TelemetryReadingViewData(
      key: 'temperature',
      label: 'Temperature',
      value: 0,
      unit: ' C',
      availability: TelemetryAvailability.live,
    );
    final missing = TelemetryReadingViewData.unavailable(
      key: 'fuel',
      label: 'Fuel level',
      unit: '%',
    );
    expect(zero.displayValue, '0 C');
    expect(missing.displayValue, 'Not reported');
    expect(missing.hasReading, isFalse);
  });

  test('shared states preserve severity, trend, and availability labels', () {
    final notEquipped = TelemetryReadingViewData.notEquipped(
      key: 'humidity',
      label: 'Humidity',
      unit: '%',
    );
    const stale = TelemetryReadingViewData(
      key: 'fuel',
      label: 'Fuel',
      value: 22,
      unit: '%',
      severity: TelemetrySeverity.warning,
      trend: TelemetryTrend.falling,
      availability: TelemetryAvailability.stale,
    );
    expect(notEquipped.displayValue, 'Not equipped');
    expect(stale.availabilityLabel, 'Stale');
    expect(stale.severity, TelemetrySeverity.warning);
    expect(stale.trend, TelemetryTrend.falling);
  });

  test('demo cold-chain data is limited to equipped vehicles', () {
    final equipped = DemoTelemetryFixtures.readingsForVehicle({
      'plate': 'DEMO-TRK-01',
    });
    final standard = DemoTelemetryFixtures.readingsForVehicle({
      'plate': 'REAL-TRK-01',
    });
    expect(equipped.first.hasReading, isTrue);
    expect(standard.first.availability, TelemetryAvailability.notEquipped);
    expect(
      standard.firstWhere((reading) => reading.key == 'fuel').displayValue,
      'Not reported',
    );
  });
}
