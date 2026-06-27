<?php

use App\Models\MaintenanceWorkOrder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;

uses(RefreshDatabase::class);

beforeEach(function (): void {
    Cache::put('geotab_fleet_snapshot_v4_fresh', [
        'vehicles' => [
            [
                'plate' => 'WO-TRK-01',
                'geotabId' => 'device-work-order-1',
                'isCommunicating' => true,
                'odometerKm' => 45000,
                'engineHours' => 1200,
            ],
        ],
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
        'maintenanceFaults' => [
            [
                'id' => 'fault-work-order-1',
                'vehicle' => 'WO-TRK-01',
                'geotabId' => 'device-work-order-1',
                'faultCode' => 'P0128',
                'failureMode' => 'Coolant thermostat',
                'description' => 'Coolant temperature below regulated range.',
                'severity' => 'High',
                'displayDate' => '2026-06-25',
            ],
        ],
        'maintenanceDvir' => [],
        'maintenanceWorkOrders' => [],
        'maintenanceMeasurements' => [],
        'fuel' => [
            'transactions' => [],
            'chargeEvents' => [],
        ],
        'telemetry' => ['assets' => []],
        'temperature' => [],
        'compliance' => [],
        'reports' => [
            'unmatchedRoutes' => [],
            'driverCongregation' => [],
        ],
        'lastSyncedAt' => now()->toIso8601String(),
    ], now()->addMinutes(10));
});

test('maintenance staff can create and progress a native work order', function () {
    $created = $this->postJson('/api/fleet/maintenance/work-orders', [
        'vehicleGeotabId' => 'device-work-order-1',
        'vehiclePlate' => 'WO-TRK-01',
        'title' => 'Replace coolant sensor',
        'description' => 'Inspect and replace coolant sensor after GeoTab fault review.',
        'priority' => 'high',
        'sourceType' => 'geotab_fault',
        'sourceRecordId' => 'fault-work-order-1',
        'sourceSummary' => 'FaultData P0128 was active.',
        'assignedTo' => 'Maintenance Staff',
        'estimatedCost' => 8500,
    ])
        ->assertOk()
        ->assertJsonPath('data.vehiclePlate', 'WO-TRK-01')
        ->assertJsonPath('data.sourceType', 'geotab_fault')
        ->assertJsonPath('data.status', 'assigned')
        ->assertJsonPath('data.estimatedCostLabel', 'PHP 8,500.00');

    $workOrderId = $created->json('data.id');

    $this->patchJson('/api/fleet/maintenance/work-orders/'.$workOrderId, [
        'status' => 'in_progress',
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'in_progress');

    $this->postJson('/api/fleet/maintenance/work-orders/'.$workOrderId.'/attachments', [
        'fileName' => 'receipt.png',
        'fileType' => 'image/png',
        'kind' => 'receipt',
        'dataUrl' => 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
    ])
        ->assertOk()
        ->assertJsonPath('data.attachmentCount', 1)
        ->assertJsonPath('data.hasProof', true);

    $this->patchJson('/api/fleet/maintenance/work-orders/'.$workOrderId, [
        'status' => 'completed',
        'actualCost' => 9100,
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'completed')
        ->assertJsonPath('data.actualCostLabel', 'PHP 9,100.00');
});

test('geotab source records do not create duplicate native work orders', function () {
    $payload = [
        'vehicleGeotabId' => 'device-work-order-1',
        'vehiclePlate' => 'WO-TRK-01',
        'title' => 'Inspect active diagnostic fault',
        'description' => 'Review active GeoTab fault before next dispatch.',
        'priority' => 'high',
        'sourceType' => 'geotab_fault',
        'sourceRecordId' => 'fault-work-order-1',
    ];

    $first = $this->postJson('/api/fleet/maintenance/work-orders', $payload)
        ->assertOk()
        ->json('data.id');

    $second = $this->postJson('/api/fleet/maintenance/work-orders', [
        ...$payload,
        'title' => 'Duplicate should be ignored',
    ])
        ->assertOk()
        ->json('data.id');

    expect($second)->toBe($first);
    expect(MaintenanceWorkOrder::query()->count())->toBe(1);
});

test('native work orders replace matching geotab suggestions in the maintenance list', function () {
    MaintenanceWorkOrder::query()->create([
        'vehicle_geotab_id' => 'device-work-order-1',
        'vehicle_plate' => 'WO-TRK-01',
        'title' => 'Native fault repair order',
        'description' => 'This should suppress the matching GeoTab suggestion.',
        'priority' => 'high',
        'status' => 'open',
        'source_type' => 'geotab_fault',
        'source_record_id' => 'fault-work-order-1',
    ]);

    $orders = $this->getJson('/api/fleet/maintenance/work-orders')
        ->assertOk()
        ->json('data');

    expect($orders)->toHaveCount(1);
    expect($orders[0]['isNativeWorkOrder'])->toBeTrue();
    expect($orders[0]['title'])->toBe('Native fault repair order');
});
