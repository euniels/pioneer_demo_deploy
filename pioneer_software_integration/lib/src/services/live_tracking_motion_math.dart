import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';

class LiveTrackingMotionMath {
  const LiveTrackingMotionMath._();

  static const double metersPerLatitudeDegree = 111320.0;

  static LatLng estimatePosition({
    required LatLng basePosition,
    required Duration elapsed,
    required double speedKph,
    required double headingDegrees,
    required bool ignitionOn,
    double stationaryThresholdKph = 2.0,
    Duration maxDuration = const Duration(seconds: 32),
  }) {
    if (!ignitionOn ||
        speedKph < stationaryThresholdKph ||
        elapsed <= Duration.zero) {
      return basePosition;
    }

    final clampedElapsed = elapsed > maxDuration ? maxDuration : elapsed;
    final speedMps = speedKph / 3.6;
    final meters = speedMps * clampedElapsed.inMicroseconds / 1000000.0;
    final headingRadians = degreesToRadians(headingDegrees);
    final latRadians = degreesToRadians(basePosition.latitude);
    final cosLatRaw = math.cos(latRadians);
    final cosLat = cosLatRaw.abs() < 0.000001 ? 0.000001 : cosLatRaw;

    final deltaLat =
        (meters / metersPerLatitudeDegree) * math.cos(headingRadians);
    final deltaLng =
        (meters / (metersPerLatitudeDegree * cosLat)) *
        math.sin(headingRadians);

    return LatLng(
      basePosition.latitude + deltaLat,
      basePosition.longitude + deltaLng,
    );
  }

  static double snapThresholdMeters({
    required double previousSpeedKph,
    required double nextSpeedKph,
    required Duration pollInterval,
    double maximumTravelMultiplier = 1.5,
    double minimumMeters = 180.0,
  }) {
    final speedMps = math.max(previousSpeedKph, nextSpeedKph) / 3.6;
    final expectedTravel = speedMps * pollInterval.inMilliseconds / 1000.0;
    return math.max(minimumMeters, expectedTravel * maximumTravelMultiplier);
  }

  static bool isPointInsideBufferedBounds(
    LatLng point,
    gmaps.LatLngBounds bounds, {
    double bufferFraction = 0.2,
  }) {
    final south = bounds.southwest.latitude;
    final north = bounds.northeast.latitude;
    final west = bounds.southwest.longitude;
    final east = bounds.northeast.longitude;
    final latSpan = (north - south).abs();
    final bufferedSouth = south - (latSpan * bufferFraction);
    final bufferedNorth = north + (latSpan * bufferFraction);

    if (point.latitude < bufferedSouth || point.latitude > bufferedNorth) {
      return false;
    }

    final lngSpan = east >= west ? east - west : (180 - west) + (east + 180);
    final lngBuffer = lngSpan * bufferFraction;
    final bufferedWest = normalizeLongitude(west - lngBuffer);
    final bufferedEast = normalizeLongitude(east + lngBuffer);
    final lng = normalizeLongitude(point.longitude);

    if (bufferedWest <= bufferedEast) {
      return lng >= bufferedWest && lng <= bufferedEast;
    }

    return lng >= bufferedWest || lng <= bufferedEast;
  }

  static double degreesToRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  static double normalizeLongitude(double longitude) {
    var value = longitude;
    while (value < -180) {
      value += 360;
    }
    while (value > 180) {
      value -= 360;
    }
    return value;
  }
}
