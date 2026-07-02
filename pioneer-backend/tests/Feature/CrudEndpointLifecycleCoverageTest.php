<?php

use App\Models\BillingInvoiceReference;
use App\Models\FleetRoute;
use App\Models\MaintenanceHistory;
use App\Models\ManualDriver;
use App\Models\ManualVehicle;
use App\Models\ProofOfDelivery;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Hash;

uses(RefreshDatabase::class);

beforeEach(function (): void {
    crudSeedSnapshot();
});

function crudVerifiedPodPayload(): array
{
    return [
        'recipientName' => 'CRUD Test Receiver',
        'status' => 'delivered',
        'signatureDataUrl' => 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
    ];
}

function crudBillingStatusSignaturePayload(string $status, string $role = 'finance'): array
{
    return [
        'billingSignatureRole' => $role,
        'billingSignatureDataUrl' => json_encode([
            'status' => $status,
            'signedAt' => now()->toIso8601String(),
            'strokes' => [
                [
                    ['x' => 0, 'y' => 0],
                    ['x' => 12, 'y' => 8],
                ],
            ],
        ], JSON_THROW_ON_ERROR),
    ];
}

function crudSeedSnapshot(array $overrides = []): void
{
    $snapshot = array_replace_recursive([
        'vehicles' => [],
        'drivers' => [],
        'trips' => [],
        'routes' => [],
        'zones' => [],
        'dashboard' => [],
        'billings' => [],
        'billingOverview' => [],
        'soa' => ['clients' => []],
        'maintenance' => [],
        'maintenanceOverview' => [],
        'maintenanceFaults' => [],
        'maintenanceDvir' => [],
        'maintenanceWorkOrders' => [],
        'maintenanceMeasurements' => [],
        'fuel' => [
            'transactions' => [],
            'chargeEvents' => [],
        ],
        'telemetry' => [
            'assets' => [],
        ],
        'temperature' => [],
        'compliance' => [],
        'reports' => [
            'unmatchedRoutes' => [],
            'driverCongregation' => [],
        ],
        'lastSyncedAt' => now()->toIso8601String(),
    ], $overrides);

    Cache::put('geotab_fleet_snapshot_v4_fresh', $snapshot, now()->addMinutes(10));
    Cache::put('geotab_fleet_snapshot_v4_stale', $snapshot, now()->addMinutes(30));
}

function crudHeaders(string $role = 'super_administrator'): array
{
    return ['X-Pioneer-Role' => $role];
}

function crudTripPayload(array $overrides = []): array
{
    return [
        'tripId' => 'TRP-CRUD-'.strtoupper(substr(md5(json_encode($overrides).microtime()), 0, 6)),
        'customer' => 'CRUD Client',
        'origin' => 'Pioneer Warehouse',
        'destination' => 'Client Receiving',
        'cargoType' => 'General',
        'totalWeightKg' => 500,
        'orderValue' => 120000,
        'amount' => 2500,
        'vehicle' => 'PTC-CRUD',
        'driver' => 'CRUD Driver',
        'scheduledDepartureAt' => now()->addDay()->toIso8601String(),
        ...$overrides,
    ];
}

function crudRoutePayload(array $overrides = []): array
{
    return [
        'name' => 'CRUD Route',
        'description' => 'Lifecycle route.',
        'assignedVehicleGeotabId' => 'device-route-crud',
        'assignedVehiclePlate' => 'PTC-R01',
        'stops' => [
            ['name' => 'Depot', 'zoneId' => 'zone-a', 'latitude' => 14.2788, 'longitude' => 121.1248],
            ['name' => 'Client', 'zoneId' => 'zone-b', 'latitude' => 14.3001, 'longitude' => 121.1402],
        ],
        ...$overrides,
    ];
}

function crudVehiclePayload(array $overrides = []): array
{
    return [
        'plateNumber' => 'PTC-'.strtoupper(substr(md5(json_encode($overrides).microtime()), 0, 4)),
        'vehicleType' => 'Drop-side Truck',
        'fuelType' => 'Diesel',
        'cargoCapacityKg' => 4500,
        'registrationExpiryDate' => now()->addYear()->toDateString(),
        ...$overrides,
    ];
}

function crudClientPayload(array $overrides = []): array
{
    return [
        'companyName' => 'CRUD Client '.strtoupper(substr(md5(json_encode($overrides).microtime()), 0, 4)),
        'contactPersonName' => 'Ana Reyes',
        'contactNumber' => '09171234567',
        'billingAddress' => 'Cabuyao, Laguna',
        'clientType' => 'Regular',
        'paymentTerms' => 'COD',
        ...$overrides,
    ];
}

function crudMaintenancePayload(array $overrides = []): array
{
    return [
        'vehicleGeotabId' => 'device-maint-crud',
        'vehiclePlate' => 'PTC-M01',
        'recordedAt' => now()->toIso8601String(),
        'odometerKm' => 12500,
        'type' => 'Preventive Maintenance Service',
        'description' => 'PMS completed with full remarks.',
        'notes' => 'C3-04 remarks recorded.',
        ...$overrides,
    ];
}

function crudZonePayload(array $overrides = []): array
{
    return [
        'name' => 'CRUD Zone',
        'zoneType' => 'Customer Site',
        'boundaryPoints' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
        ...$overrides,
    ];
}

test('client tracking formats pod demo attachment metadata without string path crash', function (): void {
    $tripId = 'TRP-POD-METADATA';
    crudSeedSnapshot(['trips' => [crudTripPayload([
        'tripId' => $tripId,
        'status' => 'completed',
        'startedAt' => now()->subHours(3)->toIso8601String(),
        'endedAt' => now()->subHours(2)->toIso8601String(),
    ])]]);

    ProofOfDelivery::query()->create([
        'trip_id' => $tripId,
        'tracking_token' => 'demo-token-pod-metadata',
        'recipient_name' => 'Demo Receiver',
        'notes' => 'Demo POD verified by accounting.',
        'signature_data_url' => null,
        'status' => 'verified',
        'delivered_at' => now()->subHours(2),
        'attachments' => [
            ['name' => 'demo-pod-photo.jpg', 'type' => 'image/jpeg', 'demo' => true],
        ],
        'meta' => ['demo_data' => true],
    ]);

    $this->withHeaders(crudHeaders())
        ->getJson('/api/fleet/client-tracking/'.$tripId)
        ->assertOk()
        ->assertJsonPath('data.proofOfDelivery.attachments.0.name', 'demo-pod-photo.jpg')
        ->assertJsonPath('data.proofOfDelivery.attachments.0.type', 'image/jpeg')
        ->assertJsonPath('data.proofOfDelivery.attachments.0.demo', true);
});

test('crud 1 trips expose create validation list detail update role denial and cancel lifecycle', function (): void {
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/trips', [
        'customer' => 'Missing route fields',
    ])->assertStatus(422);

    $tripId = 'TRP-CRUD-LIFE';
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/trips', crudTripPayload(['tripId' => $tripId]))
        ->assertOk()
        ->assertJsonPath('data.tripId', $tripId)
        ->assertJsonPath('data.status', 'pending');
    crudSeedSnapshot(['trips' => [crudTripPayload(['tripId' => $tripId, 'status' => 'pending'])]]);

    $this->withHeaders(crudHeaders())->getJson('/api/fleet/trips')
        ->assertOk();
    $this->withHeaders(crudHeaders())->getJson('/api/fleet/trips/'.$tripId)
        ->assertOk()
        ->assertJsonPath('data.tripId', $tripId);
    $this->withHeaders(crudHeaders())->patchJson('/api/fleet/trips/'.$tripId, [
        'driver' => 'Edited Driver',
    ])->assertOk()->assertJsonPath('data.driver', 'Edited Driver');
    crudSeedSnapshot(['trips' => [crudTripPayload(['tripId' => $tripId, 'driver' => 'Edited Driver', 'status' => 'pending'])]]);

    $this->withHeaders(crudHeaders('accounting_staff'))->postJson('/api/fleet/trips', crudTripPayload([
        'tripId' => 'TRP-ACCOUNTING-DENIED',
    ]))->assertForbidden();

    $this->withHeaders(crudHeaders())->patchJson('/api/fleet/trips/'.$tripId, [
        'status' => 'cancelled',
        'cancellationReason' => 'Client cancelled before dispatch.',
    ])->assertOk()->assertJsonPath('data.status', 'cancelled');
});

test('crud 2 routes expose full lifecycle and active dependency protection', function (): void {
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/routes', ['description' => 'Missing name'])
        ->assertStatus(422);

    $created = $this->withHeaders(crudHeaders())->postJson('/api/fleet/routes', crudRoutePayload())
        ->assertOk()
        ->assertJsonPath('data.stopCount', 2);
    $routeId = $created->json('data.id');

    $this->withHeaders(crudHeaders())->getJson('/api/fleet/routes')->assertOk();
    $this->withHeaders(crudHeaders())->getJson('/api/fleet/routes/'.$routeId)
        ->assertOk()
        ->assertJsonPath('data.name', 'CRUD Route');
    $this->withHeaders(crudHeaders())->patchJson('/api/fleet/routes/'.$routeId, [
        'name' => 'CRUD Route Edited',
    ])->assertOk()->assertJsonPath('data.name', 'CRUD Route Edited');

    $this->withHeaders(crudHeaders('dispatcher'))->deleteJson('/api/fleet/routes/'.$routeId)
        ->assertForbidden();

    $blocked = FleetRoute::query()->create([
        'name' => 'Blocked Active Route',
        'geotab_route_id' => 'route-active-crud',
        'status' => 'active',
    ]);
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/trips', crudTripPayload([
        'tripId' => 'TRP-ROUTE-BLOCK',
        'status' => 'dispatched',
        'routeGeotabId' => 'route-active-crud',
    ]))->assertOk();
    crudSeedSnapshot(['trips' => [crudTripPayload([
        'tripId' => 'TRP-ROUTE-BLOCK',
        'status' => 'dispatched',
        'routeGeotabId' => 'route-active-crud',
    ])]]);
    $this->withHeaders(crudHeaders())->deleteJson('/api/fleet/routes/local-route-'.$blocked->id)
        ->assertStatus(423);

    $this->withHeaders(crudHeaders())->deleteJson('/api/fleet/routes/'.$routeId)
        ->assertOk()
        ->assertJsonPath('data.status', 'deleted');
});

test('crud 3 vehicles expose lifecycle and active trip deactivation block', function (): void {
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/vehicles/manual', [
        'plateNumber' => 'BAD-VEH',
    ])->assertStatus(422);

    $created = $this->withHeaders(crudHeaders())->postJson('/api/fleet/vehicles/manual', crudVehiclePayload([
        'plateNumber' => 'PTC-V01',
    ]))->assertOk()->assertJsonPath('data.plate', 'PTC-V01');
    $vehicleId = $created->json('data.localId');

    $this->withHeaders(crudHeaders())->getJson('/api/fleet/vehicles/manual')->assertOk();
    $this->withHeaders(crudHeaders())->getJson('/api/fleet/vehicles/manual/'.$vehicleId)
        ->assertOk()
        ->assertJsonPath('data.plate', 'PTC-V01');
    $this->withHeaders(crudHeaders())->patchJson('/api/fleet/vehicles/manual/'.$vehicleId, [
        'vehicleType' => 'Refrigerated Truck',
    ])->assertOk()->assertJsonPath('data.vehicleType', 'Refrigerated Truck');

    $this->withHeaders(crudHeaders('dispatcher'))->postJson('/api/fleet/vehicles/manual', crudVehiclePayload([
        'plateNumber' => 'PTC-DENY',
    ]))->assertForbidden();

    ManualVehicle::query()->create([
        'plate_number' => 'PTC-BLOCK',
        'vehicle_type' => 'Drop-side Truck',
        'fuel_type' => 'Diesel',
        'cargo_capacity_kg' => 4000,
        'registration_expiry_date' => now()->addYear(),
        'status' => 'active',
    ]);
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/trips', crudTripPayload([
        'tripId' => 'TRP-VEH-BLOCK',
        'vehicle' => 'PTC-BLOCK',
        'status' => 'dispatched',
    ]))->assertOk();
    crudSeedSnapshot(['trips' => [crudTripPayload([
        'tripId' => 'TRP-VEH-BLOCK',
        'vehicle' => 'PTC-BLOCK',
        'status' => 'dispatched',
    ])]]);
    $this->withHeaders(crudHeaders())->deleteJson('/api/fleet/vehicles/manual/PTC-BLOCK', [
        'reason' => 'Should be blocked.',
    ])->assertStatus(423);
    $this->withHeaders(crudHeaders())->deleteJson('/api/fleet/vehicles/manual/PTC-BLOCK/permanent')
        ->assertStatus(409)
        ->assertJsonPath(
            'message',
            'This vehicle has trip history and cannot be deleted. Use Deactivate instead to preserve records.'
        );

    $this->withHeaders(crudHeaders())->deleteJson('/api/fleet/vehicles/manual/'.$vehicleId, [
        'reason' => 'Reserve unit.',
    ])->assertOk()->assertJsonPath('data.status', 'inactive');
    $this->withHeaders(crudHeaders())->deleteJson('/api/fleet/vehicles/manual/'.$vehicleId.'/permanent')
        ->assertOk()
        ->assertJsonPath('data.deleted', true);
});

test('driver hard delete refuses trip history and permits unused local drivers', function (): void {
    $protected = ManualDriver::query()->create([
        'name' => 'Protected Manual Driver',
        'status' => 'inactive',
    ]);
    crudSeedSnapshot(['trips' => [crudTripPayload([
        'driver' => 'Protected Manual Driver',
        'status' => 'completed',
    ])]]);

    $this->withHeaders(crudHeaders())
        ->deleteJson('/api/fleet/drivers/manual/'.$protected->id.'/permanent')
        ->assertStatus(409)
        ->assertJsonPath(
            'message',
            'This driver has trip history and cannot be deleted. Use Deactivate instead to preserve records.'
        );

    $unused = ManualDriver::query()->create([
        'name' => 'Unused Manual Driver',
        'status' => 'inactive',
    ]);
    crudSeedSnapshot();

    $this->withHeaders(crudHeaders())
        ->deleteJson('/api/fleet/drivers/manual/'.$unused->id.'/permanent')
        ->assertOk()
        ->assertJsonPath('data.deleted', true);
});

test('crud 4 clients expose lifecycle and role denial', function (): void {
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/clients', [
        'companyName' => 'Missing contact',
    ])->assertStatus(422);

    $created = $this->withHeaders(crudHeaders())->postJson('/api/fleet/clients', crudClientPayload([
        'companyName' => 'CRUD Client Lifecycle',
    ]))->assertOk()->assertJsonPath('data.companyName', 'CRUD Client Lifecycle');
    $clientId = $created->json('data.id');

    $this->withHeaders(crudHeaders())->getJson('/api/fleet/clients')->assertOk();
    $this->withHeaders(crudHeaders())->getJson('/api/fleet/clients/'.$clientId)
        ->assertOk()
        ->assertJsonPath('data.companyName', 'CRUD Client Lifecycle');
    $this->withHeaders(crudHeaders())->patchJson('/api/fleet/clients/'.$clientId, [
        'billingAddress' => 'Updated Billing Address',
    ])->assertOk()->assertJsonPath('data.billingAddress', 'Updated Billing Address');

    $this->withHeaders(crudHeaders('dispatcher'))->postJson('/api/fleet/clients', crudClientPayload([
        'companyName' => 'Denied Client',
    ]))->assertForbidden();

    $this->withHeaders(crudHeaders())->deleteJson('/api/fleet/clients/'.$clientId, [
        'reason' => 'Inactive account.',
    ])->assertOk()->assertJsonPath('data.status', 'inactive');
});

test('crud 5 maintenance exposes lifecycle, validation, read-only source block, and voiding', function (): void {
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/maintenance/history', [
        'vehiclePlate' => 'PTC-M01',
    ])->assertStatus(422);

    $created = $this->withHeaders(crudHeaders())->postJson('/api/fleet/maintenance/history', crudMaintenancePayload())
        ->assertOk()
        ->assertJsonPath('data.vehiclePlate', 'PTC-M01');
    $historyId = $created->json('data.id');

    $this->withHeaders(crudHeaders())->getJson('/api/fleet/maintenance/history')->assertOk();
    $this->withHeaders(crudHeaders())->getJson('/api/fleet/maintenance/history/'.$historyId)
        ->assertOk()
        ->assertJsonPath('data.id', (string) $historyId);
    $this->withHeaders(crudHeaders())->patchJson('/api/fleet/maintenance/history/'.$historyId, [
        'notes' => 'Updated maintenance note.',
    ])->assertOk()->assertJsonPath('data.notes', 'Updated maintenance note.');

    $this->withHeaders(crudHeaders('dispatcher'))->postJson('/api/fleet/maintenance/history', crudMaintenancePayload([
        'vehiclePlate' => 'PTC-DENY-M',
    ]))->assertForbidden();

    $geotab = MaintenanceHistory::query()->create([
        'vehicle_plate' => 'PTC-GEO',
        'type' => 'Oil Change',
        'description' => 'GeoTab sourced',
        'status' => 'recorded',
        'source' => 'geotab',
        'recorded_at' => now(),
        'odometer_km' => 13000,
    ]);
    $this->withHeaders(crudHeaders())->patchJson('/api/fleet/maintenance/history/'.$geotab->id, [
        'type' => 'Battery',
    ])->assertStatus(423);

    $this->withHeaders(crudHeaders())->patchJson('/api/fleet/maintenance/history/'.$historyId, [
        'voidReason' => 'Entered in error.',
    ])->assertOk()->assertJsonPath('data.status', 'voided');
});

test('crud 6 invoices expose lifecycle and paid void dependency block', function (): void {
    $this->withHeaders(crudHeaders())->postJson('/api/billing/invoices', [
        'overrideReason' => 'Missing trip.',
    ])->assertStatus(422);

    $tripId = 'TRP-INVOICE-CRUD';
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/trips', crudTripPayload([
        'tripId' => $tripId,
        'status' => 'completed',
    ]))->assertOk();
    crudSeedSnapshot(['trips' => [crudTripPayload([
        'tripId' => $tripId,
        'status' => 'completed',
    ])]]);

    $this->withHeaders(crudHeaders())->postJson('/api/billing/invoices', [
        'tripId' => $tripId,
        'status' => 'draft',
        'overrideReason' => 'Manual accounting edge case.',
        'lineItems' => [
            ['label' => 'Delivery charge', 'amount' => 2500],
        ],
    ])->assertOk()->assertJsonPath('data.tripId', $tripId);
    crudSeedSnapshot(['trips' => [crudTripPayload([
        'tripId' => $tripId,
        'status' => 'completed',
    ])]]);

    $this->withHeaders(crudHeaders())->getJson('/api/billing/invoices')->assertOk();
    $this->withHeaders(crudHeaders())->getJson('/api/billing/invoices/'.$tripId)
        ->assertOk()
        ->assertJsonPath('data.tripId', $tripId);
    $this->withHeaders(crudHeaders())->patchJson('/api/billing/invoices/'.$tripId, [
        'status' => 'approved',
        'approvalNote' => 'Missing POD should block approval.',
    ])->assertStatus(422);

    $this->withHeaders(crudHeaders())->postJson('/api/fleet/pod/'.$tripId, crudVerifiedPodPayload())
        ->assertOk()
        ->assertJsonPath('data.status', 'delivered');

    $this->withHeaders(crudHeaders())->patchJson('/api/billing/invoices/'.$tripId, [
        'status' => 'approved',
        'approvalNote' => 'Completed trip and POD checked.',
        ...crudBillingStatusSignaturePayload('approved', 'admin'),
    ])->assertOk()->assertJsonPath('data.status', 'approved');

    $this->withHeaders(crudHeaders())->patchJson('/api/billing/invoices/'.$tripId, [
        'status' => 'issued',
        'finalChargeBasis' => 'Final delivery charge confirmed from trip record.',
        ...crudBillingStatusSignaturePayload('issued', 'admin'),
    ])->assertOk()->assertJsonPath('data.status', 'issued');
    crudSeedSnapshot(['trips' => [crudTripPayload([
        'tripId' => $tripId,
        'status' => 'completed',
    ])]]);

    $this->withHeaders(crudHeaders('dispatcher'))->postJson('/api/billing/invoices', [
        'tripId' => $tripId,
        'overrideReason' => 'Denied.',
    ])->assertForbidden();

    $this->withHeaders(crudHeaders())->postJson('/api/billing/invoices/'.$tripId.'/void', [
        'reason' => 'Duplicate invoice.',
    ])->assertOk()->assertJsonPath('data.status', 'voided');

    $paidTripId = 'TRP-INVOICE-PAID-BLOCK';
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/trips', crudTripPayload([
        'tripId' => $paidTripId,
        'status' => 'completed',
    ]))->assertOk();
    crudSeedSnapshot(['trips' => [crudTripPayload([
        'tripId' => $paidTripId,
        'status' => 'completed',
    ])]]);
    BillingInvoiceReference::query()->create([
        'trip_id' => $paidTripId,
        'invoice_number' => 'INV-PAID-BLOCK',
        'status' => 'paid',
    ]);
    $this->withHeaders(crudHeaders())->postJson('/api/billing/invoices/'.$paidTripId.'/void', [
        'reason' => 'Should be blocked.',
    ])->assertStatus(423);
});

test('crud 7 zones expose lifecycle and role denial', function (): void {
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/zones', [
        'name' => 'Invalid Zone',
    ])->assertStatus(422);

    $created = $this->withHeaders(crudHeaders())->postJson('/api/fleet/zones', crudZonePayload())
        ->assertOk()
        ->assertJsonPath('data.name', 'CRUD Zone');
    $zoneId = $created->json('data.id');

    $this->withHeaders(crudHeaders())->getJson('/api/fleet/zones')->assertOk();
    $this->withHeaders(crudHeaders())->getJson('/api/fleet/zones/'.$zoneId)
        ->assertOk()
        ->assertJsonPath('data.name', 'CRUD Zone');
    $this->withHeaders(crudHeaders())->patchJson('/api/fleet/zones/'.$zoneId, [
        'name' => 'CRUD Zone Edited',
    ])->assertOk()->assertJsonPath('data.name', 'CRUD Zone Edited');

    $this->withHeaders(crudHeaders('dispatcher'))->postJson('/api/fleet/zones', crudZonePayload([
        'name' => 'Denied Zone',
    ]))->assertForbidden();

    $this->withHeaders(crudHeaders())->deleteJson('/api/fleet/zones/'.$zoneId)
        ->assertOk()
        ->assertJsonPath('data.status', 'deleted');
});

test('crud 8 users expose lifecycle and active driver dependency block', function (): void {
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/users', [
        'email' => 'missing-name@example.test',
    ])->assertStatus(422);

    $created = $this->withHeaders(crudHeaders())->postJson('/api/fleet/users', [
        'fullName' => 'CRUD Dispatcher',
        'email' => 'crud.dispatcher@example.test',
        'role' => 'dispatcher',
        'temporaryPassword' => 'TempPass123!',
    ])->assertOk()->assertJsonPath('data.role', 'dispatcher');
    $userId = $created->json('data.id');

    $this->withHeaders(crudHeaders())->getJson('/api/fleet/users')->assertOk();
    $this->withHeaders(crudHeaders())->getJson('/api/fleet/users/'.$userId)
        ->assertOk()
        ->assertJsonPath('data.email', 'crud.dispatcher@example.test');
    $this->withHeaders(crudHeaders())->patchJson('/api/fleet/users/'.$userId, [
        'fullName' => 'CRUD Dispatcher Edited',
    ])->assertOk()->assertJsonPath('data.fullName', 'CRUD Dispatcher Edited');

    $this->withHeaders(crudHeaders('dispatcher'))->postJson('/api/fleet/users', [
        'fullName' => 'Denied User',
        'email' => 'denied.user@example.test',
        'role' => 'driver',
        'temporaryPassword' => 'TempPass123!',
    ])->assertForbidden();

    $this->withHeaders(crudHeaders())->deleteJson('/api/fleet/users/'.$userId, [
        'reason' => 'Lifecycle done.',
    ])->assertOk()->assertJsonPath('data.status', 'inactive');

    $driver = User::query()->create([
        'name' => 'Blocked Driver',
        'email' => 'blocked.driver@example.test',
        'password' => Hash::make('TempPass123!'),
        'role' => 'driver',
        'status' => 'active',
    ]);
    $this->withHeaders(crudHeaders())->postJson('/api/fleet/trips', crudTripPayload([
        'tripId' => 'TRP-USER-BLOCK-CRUD',
        'driver' => 'Blocked Driver',
        'status' => 'dispatched',
    ]))->assertOk();
    crudSeedSnapshot(['trips' => [crudTripPayload([
        'tripId' => 'TRP-USER-BLOCK-CRUD',
        'driver' => 'Blocked Driver',
        'status' => 'dispatched',
    ])]]);
    $this->withHeaders(crudHeaders())->deleteJson('/api/fleet/users/'.$driver->id, [
        'reason' => 'Should be blocked.',
    ])->assertStatus(423);
});

test('crud 9 system settings expose read update validation and role denial', function (): void {
    $this->withHeaders(crudHeaders())->getJson('/api/fleet/settings/system')
        ->assertOk()
        ->assertJsonPath('success', true);

    $this->withHeaders(crudHeaders())->putJson('/api/fleet/settings/system', [
        'humidityAlertMinPercent' => 90,
        'humidityAlertMaxPercent' => 50,
    ])->assertStatus(422);

    $this->withHeaders(crudHeaders())->putJson('/api/fleet/settings/system', [
        'vatRatePercent' => 12,
        'freeDeliveryThreshold' => 100000,
        'actor' => 'crud-test',
    ])->assertOk()->assertJsonPath('data.vatRatePercent', 12);

    $this->withHeaders(crudHeaders('system_administrator'))->putJson('/api/fleet/settings/system', [
        'vatRatePercent' => 10,
    ])->assertForbidden();
});
