import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/pages/dashboard_page.dart';
import 'package:pioneerpath/src/theme/app_theme.dart';

void main() {
  test(
    'dashboard route text falls back when control characters are present',
    () {
      final routeText = cleanDashboardRouteTextForDisplay({
        'routeText': 'Warehouse\u0001A -> Customer',
        'routeFallback': '14.5000\u00B0N, 121.0000\u00B0E',
      });

      expect(routeText, '14.5000\u00B0N, 121.0000\u00B0E');
    },
  );

  test('dashboard route text keeps sanitized printable backend text', () {
    final routeText = cleanDashboardRouteTextForDisplay({
      'routeText': 'Warehouse A -> Customer B',
      'routeFallback': '14.5000\u00B0N, 121.0000\u00B0E',
    });

    expect(routeText, 'Warehouse A -> Customer B');
  });

  test('dashboard semantic accent color is not the error red', () {
    expect(AppTheme.accentCyan, isNot(AppTheme.errorRed));
    expect(AppTheme.primaryGradient.colors, isNot(contains(AppTheme.errorRed)));
  });

  test(
    'dashboard trip status color tolerates backend rows without Color objects',
    () {
      expect(
        dashboardTripStatusColor({'status': 'completed'}),
        AppTheme.successGreen,
      );
      expect(
        dashboardTripStatusColor({'status': 'in transit'}),
        AppTheme.primaryBlue,
      );
      expect(
        dashboardTripStatusColor({'status': null}),
        const Color(0xFF6B7280),
      );
    },
  );
}
