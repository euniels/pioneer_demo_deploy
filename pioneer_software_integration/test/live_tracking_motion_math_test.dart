import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';
import 'package:pioneerpath/src/services/live_tracking_motion_math.dart';

void main() {
  test('estimates vehicle position from speed and north/east headings', () {
    const base = LatLng(14.6, 121.0);

    final north = LiveTrackingMotionMath.estimatePosition(
      basePosition: base,
      elapsed: const Duration(seconds: 1),
      speedKph: 36,
      headingDegrees: 0,
      ignitionOn: true,
    );
    final east = LiveTrackingMotionMath.estimatePosition(
      basePosition: base,
      elapsed: const Duration(seconds: 1),
      speedKph: 36,
      headingDegrees: 90,
      ignitionOn: true,
    );

    expect(north.latitude, greaterThan(base.latitude));
    expect((north.longitude - base.longitude).abs(), lessThan(0.000001));
    expect(east.longitude, greaterThan(base.longitude));
    expect((east.latitude - base.latitude).abs(), lessThan(0.000001));
  });

  test('stops estimation when speed is low or ignition is off', () {
    const base = LatLng(14.6, 121.0);

    expect(
      LiveTrackingMotionMath.estimatePosition(
        basePosition: base,
        elapsed: const Duration(seconds: 10),
        speedKph: 1.5,
        headingDegrees: 0,
        ignitionOn: true,
      ),
      base,
    );
    expect(
      LiveTrackingMotionMath.estimatePosition(
        basePosition: base,
        elapsed: const Duration(seconds: 10),
        speedKph: 40,
        headingDegrees: 0,
        ignitionOn: false,
      ),
      base,
    );
  });

  test('snap threshold scales with poll interval and vehicle speed', () {
    final slow = LiveTrackingMotionMath.snapThresholdMeters(
      previousSpeedKph: 0,
      nextSpeedKph: 0,
      pollInterval: const Duration(seconds: 30),
    );
    final fast = LiveTrackingMotionMath.snapThresholdMeters(
      previousSpeedKph: 72,
      nextSpeedKph: 72,
      pollInterval: const Duration(seconds: 30),
    );

    expect(slow, 180);
    expect(fast, 900);
  });

  test(
    'buffered viewport includes near-edge markers and excludes far ones',
    () {
      final bounds = gmaps.LatLngBounds(
        southwest: const gmaps.LatLng(10, 10),
        northeast: const gmaps.LatLng(20, 20),
      );

      expect(
        LiveTrackingMotionMath.isPointInsideBufferedBounds(
          const LatLng(9, 15),
          bounds,
          bufferFraction: 0.2,
        ),
        isTrue,
      );
      expect(
        LiveTrackingMotionMath.isPointInsideBufferedBounds(
          const LatLng(7, 15),
          bounds,
          bufferFraction: 0.2,
        ),
        isFalse,
      );
    },
  );
}
