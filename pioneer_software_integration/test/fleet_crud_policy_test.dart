import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/fleet_crud_policy.dart';

void main() {
  group('FleetCrudPolicy.vehicle', () {
    test('allows local managed vehicles to be edited and pushed when changed', () {
      final policy = FleetCrudPolicy.vehicle({
        'managedLocally': true,
        'localId': '12',
        'geotabId': 'b1',
        'hasLocalGeotabChanges': true,
      });

      expect(policy.scopeLabel, 'Managed + GeoTab linked');
      expect(policy.canEdit, isTrue);
      expect(policy.canDeactivate, isTrue);
      expect(policy.canDelete, isTrue);
      expect(policy.canPushToGeotab, isTrue);
    });

    test('blocks local edits for GeoTab-only vehicles', () {
      final policy = FleetCrudPolicy.vehicle({
        'managedLocally': false,
        'geotabId': 'b2',
      });

      expect(policy.scopeLabel, 'GeoTab synced');
      expect(policy.canEdit, isFalse);
      expect(policy.canDeactivate, isFalse);
      expect(policy.canDelete, isFalse);
      expect(policy.canPushToGeotab, isFalse);
      expect(policy.editDisabledReason, contains('GeoTab-synced vehicles'));
    });

    test('does not offer deactivate for already inactive vehicles', () {
      final policy = FleetCrudPolicy.vehicle({
        'managedLocally': true,
        'localId': '13',
        'status': 'inactive',
      });

      expect(policy.canEdit, isTrue);
      expect(policy.canDeactivate, isFalse);
      expect(policy.canReactivate, isTrue);
    });
  });

  group('FleetCrudPolicy.driver', () {
    test('allows manual drivers to be edited and pushed when changed', () {
      final policy = FleetCrudPolicy.driver({
        'source': 'manual',
        'id': '7',
        'assignedVehicleGeotabId': 'v1',
        'syncStatus': 'local_modified',
      });

      expect(policy.scopeLabel, 'Managed + GeoTab linked');
      expect(policy.canEdit, isTrue);
      expect(policy.canDeactivate, isTrue);
      expect(policy.canDelete, isTrue);
      expect(policy.canPushToGeotab, isTrue);
    });

    test('blocks local edits for GeoTab analytics drivers', () {
      final policy = FleetCrudPolicy.driver({
        'source': 'geotab',
        'geotabUserId': 'u1',
      });

      expect(policy.scopeLabel, 'GeoTab synced');
      expect(policy.canEdit, isFalse);
      expect(policy.canDeactivate, isFalse);
      expect(policy.canDelete, isFalse);
      expect(policy.canPushToGeotab, isFalse);
      expect(policy.editDisabledReason, contains('GeoTab-synced drivers'));
    });

    test('allows reactivation only for inactive manual drivers', () {
      final policy = FleetCrudPolicy.driver({
        'source': 'manual',
        'id': '8',
        'status': 'inactive',
      });

      expect(policy.canDeactivate, isFalse);
      expect(policy.canReactivate, isTrue);
    });
  });
}
