String formatValue(dynamic value) {
  if (value == null) {
    return 'N/A';
  }

  if (value is num) {
    return value % 1 == 0 ? value.toInt().toString() : value.toString();
  }

  final text = value.toString().trim();
  final normalized = text.toLowerCase();
  if (text.isEmpty ||
      normalized == 'unavailable' ||
      normalized == 'unknown' ||
      text == '--') {
    return 'N/A';
  }

  return text;
}

String formatCoordinateValue(dynamic latitude, dynamic longitude) {
  final lat = _toDouble(latitude);
  final lng = _toDouble(longitude);
  if (lat == null || lng == null || (lat == 0 && lng == 0)) {
    return 'N/A';
  }

  final latSuffix = lat >= 0 ? 'N' : 'S';
  final lngSuffix = lng >= 0 ? 'E' : 'W';
  return '${lat.abs().toStringAsFixed(4)}\u00B0$latSuffix, '
      '${lng.abs().toStringAsFixed(4)}\u00B0$lngSuffix';
}

double? _toDouble(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }

  if (value is String) {
    return double.tryParse(value.trim());
  }

  return null;
}
