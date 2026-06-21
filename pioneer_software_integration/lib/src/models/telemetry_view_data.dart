enum TelemetrySeverity { normal, warning, critical }

enum TelemetryTrend { rising, falling, stable }

enum TelemetryAvailability {
  live,
  stale,
  unavailable,
  unsupported,
  notEquipped,
}

class TelemetryReadingViewData {
  const TelemetryReadingViewData({
    required this.key,
    required this.label,
    required this.availability,
    this.value,
    this.unit = '',
    this.severity = TelemetrySeverity.normal,
    this.trend = TelemetryTrend.stable,
    this.updatedAt,
    this.safeMin,
    this.safeMax,
    this.source = 'GeoTab',
    this.history = const <double>[],
  });

  final String key;
  final String label;
  final double? value;
  final String unit;
  final TelemetrySeverity severity;
  final TelemetryTrend trend;
  final TelemetryAvailability availability;
  final DateTime? updatedAt;
  final double? safeMin;
  final double? safeMax;
  final String source;
  final List<double> history;

  bool get hasReading => value != null;

  String get displayValue {
    switch (availability) {
      case TelemetryAvailability.notEquipped:
        return 'Not equipped';
      case TelemetryAvailability.unsupported:
        return 'Unsupported';
      case TelemetryAvailability.unavailable:
        return 'Not reported';
      case TelemetryAvailability.live:
      case TelemetryAvailability.stale:
        if (value == null) return 'Not reported';
        final decimals = value!.abs() >= 100 || value! % 1 == 0 ? 0 : 1;
        return '${value!.toStringAsFixed(decimals)}$unit';
    }
  }

  String get availabilityLabel => switch (availability) {
    TelemetryAvailability.live => 'Live',
    TelemetryAvailability.stale => updatedAt == null
        ? 'Stale'
        : 'Stale - ${_relativeAge(updatedAt!)}',
    TelemetryAvailability.unavailable => 'Not reported',
    TelemetryAvailability.unsupported => 'Unsupported',
    TelemetryAvailability.notEquipped => 'Not equipped',
  };

  String get safeRangeLabel {
    if (safeMin == null && safeMax == null) return '';
    if (safeMin != null && safeMax != null) {
      return '${_rangeNumber(safeMin!)}-${_rangeNumber(safeMax!)}$unit';
    }
    if (safeMin != null) return 'At least ${_rangeNumber(safeMin!)}$unit';
    return 'At most ${_rangeNumber(safeMax!)}$unit';
  }

  factory TelemetryReadingViewData.fromMap({
    required String key,
    required String label,
    required Map<String, dynamic> data,
    String unit = '',
    double? safeMin,
    double? safeMax,
    String source = 'GeoTab',
  }) {
    final value = telemetryNumber(
      data['value'] ?? data['reading'] ?? data['numericValue'],
    );
    return TelemetryReadingViewData(
      key: key,
      label: label,
      value: value,
      unit: (data['unit']?.toString().trim().isNotEmpty ?? false)
          ? data['unit'].toString()
          : unit,
      severity: _severity(data['severity'] ?? data['status']),
      trend: _trend(data['trend']),
      availability: _availability(
        data['availability'] ?? data['state'],
        hasValue: value != null,
      ),
      updatedAt: _date(data['updatedAt'] ?? data['dateTime']),
      safeMin: telemetryNumber(data['safeMin']) ?? safeMin,
      safeMax: telemetryNumber(data['safeMax']) ?? safeMax,
      source: data['source']?.toString() ?? source,
      history: _history(data['history']),
    );
  }

  static TelemetryReadingViewData notEquipped({
    required String key,
    required String label,
    String unit = '',
  }) => TelemetryReadingViewData(
    key: key,
    label: label,
    unit: unit,
    availability: TelemetryAvailability.notEquipped,
  );

  static TelemetryReadingViewData unavailable({
    required String key,
    required String label,
    String unit = '',
  }) => TelemetryReadingViewData(
    key: key,
    label: label,
    unit: unit,
    availability: TelemetryAvailability.unavailable,
  );
}

double? telemetryNumber(dynamic value) {
  if (value is num) return value.toDouble();
  if (value == null) return null;
  final cleaned = value.toString().replaceAll(RegExp(r'[^0-9.\-]'), '');
  return double.tryParse(cleaned);
}

DateTime? _date(dynamic value) {
  if (value is DateTime) return value;
  return DateTime.tryParse(value?.toString() ?? '')?.toLocal();
}

List<double> _history(dynamic value) {
  if (value is! List) return const <double>[];
  return value
      .map(telemetryNumber)
      .whereType<double>()
      .toList(growable: false);
}

TelemetrySeverity _severity(dynamic value) =>
    switch (value?.toString().toLowerCase()) {
      'critical' || 'danger' || 'error' => TelemetrySeverity.critical,
      'warning' || 'review' || 'attention' => TelemetrySeverity.warning,
      _ => TelemetrySeverity.normal,
    };

TelemetryTrend _trend(dynamic value) =>
    switch (value?.toString().toLowerCase()) {
      'rising' || 'up' || 'increasing' => TelemetryTrend.rising,
      'falling' || 'down' || 'decreasing' => TelemetryTrend.falling,
      _ => TelemetryTrend.stable,
    };

TelemetryAvailability _availability(dynamic value, {required bool hasValue}) =>
    switch (value?.toString().toLowerCase()) {
      'stale' => TelemetryAvailability.stale,
      'unsupported' => TelemetryAvailability.unsupported,
      'not_equipped' || 'not equipped' => TelemetryAvailability.notEquipped,
      'unavailable' || 'not_reported' || 'not reported' =>
        TelemetryAvailability.unavailable,
      _ => hasValue
          ? TelemetryAvailability.live
          : TelemetryAvailability.unavailable,
    };

String _rangeNumber(double value) =>
    value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);

String _relativeAge(DateTime value) {
  final age = DateTime.now().difference(value);
  if (age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  if (age.inDays < 1) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}
