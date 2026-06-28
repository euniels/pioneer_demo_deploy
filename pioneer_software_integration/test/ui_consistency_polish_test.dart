import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/theme/app_theme.dart';
import 'package:pioneerpath/src/utils/form_validation.dart';
import 'package:pioneerpath/src/widgets/app_state_widgets.dart';

void main() {
  test('AppTheme exposes the Group 10 design token foundation', () {
    expect(AppTheme.pioneerDeepBlue, const Color(0xFF1A3A6B));
    expect(AppTheme.pioneerRed, const Color(0xFFC0392B));
    expect(AppTheme.pioneerBlack, const Color(0xFF1A1A1A));
    expect(AppTheme.space12, 12);
    expect(AppTheme.radiusLg, 16);
    expect(AppTheme.statusColor('overdue'), AppTheme.errorRed);
    expect(AppTheme.statusColor('in transit'), AppTheme.primaryBlue);
  });

  test('AppTheme exposes reusable system surface and text tokens', () {
    final source = File('lib/src/theme/app_theme.dart').readAsStringSync();

    expect(source, contains('textPrimary'));
    expect(source, contains('textSecondary'));
    expect(source, contains('textMuted'));
    expect(source, contains('surfaceCard'));
    expect(source, contains('surfaceInput'));
    expect(source, contains('settingsTitleStyle'));
    expect(source, contains('settingsSubtitleStyle'));
    expect(source, contains('settingsBodyStyle'));
    expect(source, contains('settingsCaptionStyle'));
  });

  test('shared page shell widgets use semantic theme tokens', () {
    final files = [
      'lib/src/widgets/dashboard_layout.dart',
      'lib/src/widgets/app_card.dart',
      'lib/src/widgets/app_state_widgets.dart',
      'lib/src/widgets/premium_glass_card.dart',
      'lib/src/widgets/workflow_timeline.dart',
      'lib/src/widgets/maintenance_card.dart',
      'lib/src/widgets/page_skeletons.dart',
    ];

    for (final path in files) {
      final source = File(path).readAsStringSync();
      final usesSharedToken = [
        'AppTheme.surfaceCard(context)',
        'AppTheme.surfacePanel(context)',
        'AppTheme.surfacePage(context)',
        'AppTheme.textPrimary(context)',
        'AppTheme.textSecondary(context)',
        'AppTheme.textDisabled(context)',
        'AppTheme.settings',
        'AppTheme.borderDefault(context)',
        'AppTheme.borderStrong(context)',
      ].any(source.contains);

      expect(usesSharedToken, isTrue, reason: '$path should use shared visual tokens.');
    }
  });

  test('admin list pages use shared search filter and summary controls', () {
    final controls = File(
      'lib/src/widgets/admin_page_controls.dart',
    ).readAsStringSync();
    final drivers = File('lib/src/pages/drivers_page.dart').readAsStringSync();
    final vehicles = File('lib/src/pages/vehicles_page.dart').readAsStringSync();
    final clients = File('lib/src/pages/clients_page.dart').readAsStringSync();
    final users = File('lib/src/pages/users_page.dart').readAsStringSync();
    final auditLogs = File(
      'lib/src/pages/audit_log_page.dart',
    ).readAsStringSync();
    final billing = File('lib/src/pages/billing_page.dart').readAsStringSync();
    final fuel = File('lib/src/pages/fuel_expenses_page.dart').readAsStringSync();
    final clientTracking = File(
      'lib/src/pages/client_tracking_page.dart',
    ).readAsStringSync();
    final maintenance = File(
      'lib/src/pages/maintenance_page.dart',
    ).readAsStringSync();
    final statements = File(
      'lib/src/pages/statements_of_accounts.dart',
    ).readAsStringSync();

    expect(controls, contains('class AdminSearchField'));
    expect(controls, contains('class AdminViewToggle'));
    expect(controls, contains('class AdminResultCount'));
    expect(controls, contains('class AdminFilterChip'));
    expect(controls, contains('class AdminSummaryCard'));
    expect(controls, contains('AppTheme.surfaceInput(context)'));
    expect(controls, contains('AppTheme.textPrimary(context)'));

    for (final source in [drivers, vehicles, clients, users]) {
      expect(source, contains('AdminSearchField'));
      expect(source, contains('AdminResultCount'));
      expect(source, contains('AdminFilterChip'));
    }

    for (final source in [drivers, vehicles]) {
      expect(source, contains('AdminViewToggle'));
    }

    expect(vehicles, contains('AdminSummaryCard'));
    expect(auditLogs, contains('AdminSearchField'));
    expect(billing, contains('AdminSearchField'));
    expect(fuel, contains('AdminResultCount'));
    expect(fuel, contains('AdminFilterChip'));
    expect(clientTracking, contains('AdminSearchField'));
    expect(maintenance, contains('AdminResultCount'));
    expect(maintenance, contains('AdminFilterChip'));
    expect(statements, contains('AdminSearchField'));
    expect(statements, contains('AdminResultCount'));
  });

  testWidgets(
    'PioneerStateCard gives empty and error states an action surface',
    (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildLightTheme(),
          home: Scaffold(
            body: PioneerStateCard(
              icon: Icons.inbox_rounded,
              title: 'Nothing here yet',
              message: 'This section will fill in once records are available.',
              actionLabel: 'Retry',
              onAction: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(
        find.text('This section will fill in once records are available.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry'));
      expect(tapped, isTrue);
    },
  );

  test(
    'driver pages use skeletons and designed states instead of blocking spinners',
    () {
      final files = [
        'lib/src/pages/driver_dashboard_page.dart',
        'lib/src/pages/driver_earnings_page.dart',
        'lib/src/pages/driver_vehicle_page.dart',
        'lib/src/pages/driver_map_page.dart',
        'lib/src/pages/driver_trips_page.dart',
      ];

      for (final path in files) {
        final source = File(path).readAsStringSync();
        expect(source, contains('PioneerRouteSkeletonBody'));
        expect(source, contains('PioneerStateCard'));
        expect(source, isNot(contains('Failed to load')));
        expect(
          source,
          isNot(contains('Center(\n        child: CircularProgressIndicator')),
        );
      }
    },
  );

  test('drivers page exposes full crud form controls and safety states', () {
    final source = File('lib/src/pages/drivers_page.dart').readAsStringSync();

    expect(source, contains('Full Name'));
    expect(source, contains('License Number'));
    expect(source, contains('License Expiry Date'));
    expect(source, contains('showDatePicker'));
    expect(source, contains('Contact Number'));
    expect(source, contains('Address'));
    expect(source, contains('Assigned Vehicle'));
    expect(source, contains('DropdownButtonFormField<String>'));
    expect(source, contains('Status'));
    expect(source, contains('Emergency Contact'));
    expect(source, contains('Deactivate driver?'));
    expect(source, contains('Driver added successfully.'));
    expect(source, contains('Driver updated successfully.'));
    expect(source, contains('Delete \$name?'));
    expect(source, contains('This cannot be undone.'));
    expect(source, contains('Reactivate'));
    expect(source, contains('Driver reactivated successfully.'));
    expect(source, contains('deleteDriverInBackend'));
    expect(source, contains('reactivateDriverInBackend'));
    expect(source, contains('License expired'));
    expect(source, contains(r'Expires in $days days'));
    expect(source, contains('Add your first driver'));
  });

  test('trips page exposes full lifecycle crud controls', () {
    final source = File('lib/src/pages/trips_page.dart').readAsStringSync();

    expect(source, contains('Create Trip'));
    expect(source, contains('Client'));
    expect(source, contains('Origin'));
    expect(source, contains('Destination'));
    expect(source, contains('Cargo type'));
    expect(source, contains('Cargo weight in kg'));
    expect(source, contains('Order value in PHP'));
    expect(source, contains('Assigned vehicle'));
    expect(source, contains('Assigned driver'));
    expect(source, contains('Scheduled departure'));
    expect(source, contains('Estimated arrival'));
    expect(source, contains('Special instructions'));
    expect(source, contains('Free delivery candidate'));
    expect(source, contains('Next Phase'));
    expect(source, contains('Cancellation reason'));
    expect(source, contains("'status': 'cancelled'"));
    expect(source, contains('_buildDesktopTripsTable'));
    expect(source, contains('LayoutBuilder'));
    expect(source, contains('DATE / TRIP'));
    expect(source, contains('Bulk Export'));
    expect(source, contains('Bulk Cancel'));
    expect(source, contains('Advance Phase'));
  });

  test('routes page exposes managed route crud and map stop picking', () {
    final source = File('lib/src/pages/routes_page.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final sidebar = File(
      'lib/src/services/sidebar_service.dart',
    ).readAsStringSync();

    expect(main, contains("case '/routes'"));
    expect(sidebar, contains("title: 'Routes'"));
    expect(source, contains('Create Route'));
    expect(source, contains('Route name'));
    expect(source, contains('Description'));
    expect(source, contains('Assigned vehicle'));
    expect(source, contains('Ordered stops'));
    expect(source, contains('GeoTab Zone ID'));
    expect(source, contains('Latitude'));
    expect(source, contains('Longitude'));
    expect(source, contains('Duration minutes'));
    expect(source, contains('Pick on map'));
    expect(source, contains('Move up'));
    expect(source, contains('Move down'));
    expect(source, contains('Soft delete'));
    expect(source, contains('PioneerGoogleMap'));
  });

  test('vehicles page exposes full managed vehicle crud controls', () {
    final source = File('lib/src/pages/vehicles_page.dart').readAsStringSync();
    final store = File(
      'lib/src/services/vehicles_store.dart',
    ).readAsStringSync();

    expect(source, contains('Plate number'));
    expect(source, contains('Vehicle type'));
    expect(source, contains('Make and model'));
    expect(source, contains('Chassis number'));
    expect(source, contains('VIN'));
    expect(source, contains('Fuel type'));
    expect(source, contains('Cargo capacity in kg'));
    expect(source, contains('GeoTab Device ID'));
    expect(source, contains('Registration expiry date'));
    expect(source, contains('Insurance expiry date'));
    expect(source, contains('Deactivate vehicle?'));
    expect(source, contains('Edit vehicle'));
    expect(source, contains('Sample'));
    expect(source, contains('Delete'));
    expect(store, contains('createVehicleInBackend'));
    expect(store, contains('updateVehicleInBackend'));
    expect(store, contains('deactivateVehicleInBackend'));
    expect(store, contains('deleteVehicleInBackend'));
  });

  test('fuel expenses filters backend records by selected vehicle', () {
    final source = File(
      'lib/src/pages/fuel_expenses_page.dart',
    ).readAsStringSync();
    final api = File('lib/src/services/backend_api.dart').readAsStringSync();

    expect(source, contains('_selectedVehicle'));
    expect(source, contains('vehicle: _selectedVehicle'));
    expect(source, contains('All vehicles'));
    expect(api, contains("queryParameters: {'vehicle': vehicle.trim()}"));
    expect(source, contains('No consumption data recorded yet.'));
    expect(source, contains('Consumption by vehicle'));
    expect(source, contains("_FuelTableHeading(label: 'DATE'"));
    expect(source, contains("_FuelTableHeading(label: 'VEHICLE'"));
    expect(source, contains("_FuelTableHeading(label: 'STATION'"));
    expect(source, contains("_FuelTableHeading(label: 'VOLUME'"));
    expect(source, contains("_FuelTableHeading(label: 'PRICE / L'"));
    expect(source, contains("_FuelTableHeading(label: 'ESTIMATED COST'"));
    expect(source, contains("_FuelTableHeading(label: 'SOURCE'"));
    expect(source, contains('color: AppTheme.primaryBlue'));
    expect(source, contains("'source': 'Manual'"));
  });

  test('clients page exposes full managed client crud and route wiring', () {
    final source = File('lib/src/pages/clients_page.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final roleService = File(
      'lib/src/services/role_service.dart',
    ).readAsStringSync();
    final trips = File('lib/src/pages/trips_page.dart').readAsStringSync();

    expect(main, contains("case '/clients'"));
    expect(roleService, contains("'/clients'"));
    expect(source, contains('New Client'));
    expect(source, contains('Company name'));
    expect(source, contains('Contact person'));
    expect(source, contains('Contact number'));
    expect(source, contains('Email address'));
    expect(source, contains('Billing address'));
    expect(source, contains('Delivery address if different'));
    expect(source, contains('Client type'));
    expect(source, contains('Payment terms'));
    expect(source, contains('Free delivery threshold override'));
    expect(source, contains('ERP Customer ID'));
    expect(source, contains('Deactivate'));
    expect(source, contains('Statement of Accounts'));
    expect(source, contains('Trip History'));
    expect(trips, contains('activeClientNames'));
    expect(trips, contains('freeDeliveryThreshold'));
  });

  test('maintenance page exposes full log crud proof and void controls', () {
    final source = File(
      'lib/src/pages/maintenance_page.dart',
    ).readAsStringSync();

    expect(source, contains('Add Maintenance Log'));
    expect(source, contains('Vehicle *'));
    expect(source, contains('Maintenance date'));
    expect(source, contains('Odometer reading at service in km'));
    expect(source, contains('Preventive Maintenance Service'));
    expect(source, contains('Corrective Repair'));
    expect(source, contains('Oil Change'));
    expect(source, contains('Service provider'));
    expect(source, contains('Cost in PHP'));
    expect(source, contains('Remarks and findings'));
    expect(source, contains('FilePicker.pickFiles'));
    expect(source, contains('Attach JPG, PNG, or PDF proof'));
    expect(source, contains('GeoTab-sourced fields are read-only'));
    expect(source, contains('Void maintenance record?'));
    expect(source, contains('Required void reason'));
    expect(source, contains('No service records found'));
    expect(source, contains('Add maintenance history to enable predictions.'));
    expect(source, contains('FaultDetailRow'));
    expect(source, contains('_buildPredictiveRiskMatrix'));
    expect(source, contains('Predictive Maintenance Risk'));
    expect(source, contains('Due Within 14 Days'));
    expect(source, contains('_buildHistoryTable'));
    expect(source, contains('SERVICE / REMARKS'));
    expect(source, contains('_MaintenanceSampleDataBanner'));
    expect(
      source,
      contains('Sample data - GeoTab did not return maintenance data.'),
    );
    expect(source, contains('_sampleHistoryRows'));
    expect(source, contains('_samplePredictiveRows'));
    expect(source, contains('isExpanded: true'));
    expect(source, contains('AppTheme.primaryBlue'));
    expect(source, contains('AppTheme.successGreen'));
    expect(source, isNot(contains('Geotab did not return rows yet')));
  });

  test(
    'zones page exposes geofence crud polygon drawing and sync controls',
    () {
      final source = File('lib/src/pages/zones_page.dart').readAsStringSync();
      final api = File('lib/src/services/backend_api.dart').readAsStringSync();

      expect(source, contains('Zones & Geofences'));
      expect(source, contains('New Zone'));
      expect(source, contains('Zone type'));
      expect(source, contains('Client association'));
      expect(source, contains('Tap the map to add at least 3 polygon points.'));
      expect(source, contains('Soft delete'));
      expect(source, contains('MOCK ZONE - UPDATE WITH ACTUAL BOUNDARY'));
      expect(source, contains('Zone removal staged for GeoTab approval.'));
      expect(source, contains('confirmedPreview: hasGeoTabSync'));
      expect(source, contains('GeoTab synced'));
      expect(api, contains('createFleetZone'));
      expect(api, contains('updateFleetZone'));
      expect(api, contains('deleteFleetZone'));
    },
  );

  test('live tracking renders fleet zone overlays on the map', () {
    final source = File(
      'lib/src/pages/live_tracking_page_enhanced.dart',
    ).readAsStringSync();

    expect(source, contains('_loadZoneOverlays'));
    expect(source, contains('_visibleZoneOverlayPolygons'));
    expect(source, contains('BackendApiService.getFleetZones'));
  });

  test('users page exposes full account and role management crud', () {
    final source = File('lib/src/pages/users_page.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final roleService = File(
      'lib/src/services/role_service.dart',
    ).readAsStringSync();
    final sidebar = File(
      'lib/src/services/sidebar_service.dart',
    ).readAsStringSync();
    final api = File('lib/src/services/backend_api.dart').readAsStringSync();
    final accountPolicy = File(
      'lib/src/services/user_account_policy.dart',
    ).readAsStringSync();
    final usersPolicySurface = '$source\n$accountPolicy';

    expect(main, contains("case '/users'"));
    expect(roleService, contains("'/users'"));
    expect(sidebar, contains("title: 'Users & Roles'"));
    expect(source, contains('Create User'));
    expect(source, contains('Full name'));
    expect(source, contains('Email address'));
    expect(source, contains('Temporary password'));
    expect(source, contains('Reset Temporary Password'));
    expect(source, contains('Deactivate User'));
    expect(source, contains('Delete User'));
    expect(source, contains('UserAccountPolicy.forUser'));
    expect(usersPolicySurface, contains('Current user'));
    expect(usersPolicySurface, contains('Privileged'));
    expect(usersPolicySurface, contains('Locked'));
    expect(source, contains('Reset Password - unavailable'));
    expect(source, contains('Deactivate - protected'));
    expect(source, contains('Shown once. Record it securely'));
    expect(source, contains('Activity Log'));
    expect(source, contains('Add your first user'));
    expect(source, contains('_normalizeRoleDisplayName'));
    expect(source, contains('dispatch_coordinator'));
    expect(source, contains('View Details'));
    expect(source, contains('_UserActionMenuItem'));
    expect(source, contains('PopupMenuPosition.under'));
    expect(
      usersPolicySurface,
      contains('Super Administrator accounts can only be deactivated.'),
    );
    expect(api, contains('/fleet/users/login-check'));
    expect(api, contains('createManagedUser'));
    expect(api, contains('updateManagedUser'));
    expect(api, contains('resetManagedUserPassword'));
    expect(api, contains('deactivateManagedUser'));
    expect(api, contains('deleteManagedUserPermanently'));
    expect(api, contains('/fleet/users/\$userId/permanent'));
  });

  test(
    'audit logs present bounded cards with collapsible filtering and diffs',
    () {
      final source = File(
        'lib/src/pages/audit_log_page.dart',
      ).readAsStringSync();

      expect(source, contains('_buildFilterPanel'));
      expect(source, contains('_buildAuditSummary'));
      expect(source, contains('audit results'));
      expect(source, contains('security events on this page'));
      expect(source, contains('Last refresh:'));
      expect(source, contains('_SecurityEventChip'));
      expect(source, contains('Security: failed login'));
      expect(source, contains('Security: settings change'));
      expect(source, contains('AnimatedSize'));
      expect(source, contains('_activeFilterCount'));
      expect(source, contains('Clear All'));
      expect(source, contains('_ActionChip'));
      expect(source, contains('Session duration'));
      expect(source, contains('_changedDiff'));
      expect(source, contains('IntrinsicHeight'));
      expect(source, contains('_DiffTone.before'));
      expect(source, contains('_DiffTone.after'));
      expect(source, contains('AppTheme.colorFFF8FBFF'));
    },
  );

  test('settings page exposes full system settings crud controls', () {
    final source = File('lib/src/pages/settings_page.dart').readAsStringSync();
    final api = File('lib/src/services/backend_api.dart').readAsStringSync();

    expect(source, contains('System Configuration'));
    expect(source, contains('Billing settings'));
    expect(source, contains('Free delivery threshold (PHP)'));
    expect(source, contains('Base delivery charge / km'));
    expect(source, contains('Fuel surcharge rate (%)'));
    expect(source, contains('GeoTab settings'));
    expect(source, contains('Backend readiness'));
    expect(source, contains('Refresh readiness'));
    expect(source, contains('Production scheduler command'));
    expect(source, contains('getApiHealth'));
    expect(source, contains('Feed seed window (days)'));
    expect(source, contains('GPS trail max points'));
    expect(source, contains('Notification settings'));
    expect(source, contains('Humidity min threshold (%)'));
    expect(source, contains('Idle alert threshold (minutes)'));
    expect(source, contains('Map settings'));
    expect(source, contains('Google Maps server key is configured'));
    expect(source, contains('Settings Change Log'));
    expect(source, contains('View full administrative audit trail'));
    expect(source, contains("Navigator.pushNamed(context, '/audit-logs')"));
    expect(source, contains('AppTheme.surfaceCard(context)'));
    expect(source, contains('AppTheme.surfaceInput(context)'));
    expect(source, contains('AppTheme.settingsTitleStyle(context)'));
    expect(source, contains('AppTheme.settingsSubtitleStyle(context)'));
    expect(source, contains('AppTheme.settingsBodyStyle(context)'));
    expect(source, contains('AppTheme.settingsCaptionStyle(context)'));
    expect(api, contains('/fleet/settings/system'));
    expect(api, contains('saveSystemSettings'));
  });

  test('shared CRUD validation rejects missing and impossible values', () {
    expect(FormValidation.requiredField('Client', ''), 'Client is required');
    expect(FormValidation.requiredSelection('vehicle', null), 'Select vehicle');
    expect(FormValidation.positiveNumber('Cargo weight', '-1'), isNotNull);
    expect(FormValidation.nonNegativeNumber('VAT', '-0.1'), isNotNull);
    expect(
      FormValidation.futureOrTodayDateText(
        'Registration expiry date',
        DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
        required: true,
      ),
      'Registration expiry date cannot be before today',
    );
  });

  test('CRUD forms use inline validation and disabled saving states', () {
    final files = {
      'clients': File('lib/src/pages/clients_page.dart').readAsStringSync(),
      'drivers': File('lib/src/pages/drivers_page.dart').readAsStringSync(),
      'vehicles': File('lib/src/pages/vehicles_page.dart').readAsStringSync(),
      'trips': File('lib/src/pages/trips_page.dart').readAsStringSync(),
      'routes': File('lib/src/pages/routes_page.dart').readAsStringSync(),
      'zones': File('lib/src/pages/zones_page.dart').readAsStringSync(),
      'maintenance': File(
        'lib/src/pages/maintenance_page.dart',
      ).readAsStringSync(),
      'billing': File('lib/src/pages/billing_page.dart').readAsStringSync(),
      'users': File('lib/src/pages/users_page.dart').readAsStringSync(),
    };

    for (final source in files.values) {
      expect(source, contains('validator:'));
      expect(source, contains('FormValidation'));
    }

    for (final key in ['clients', 'drivers', 'trips', 'users']) {
      expect(files[key], contains('_saving ? null'));
      expect(files[key], isNot(contains('Please fill all required fields')));
    }
  });
}
