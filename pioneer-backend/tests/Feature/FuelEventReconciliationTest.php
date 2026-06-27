<?php

use App\Models\FuelEvent;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;

uses(RefreshDatabase::class);

function fuelEventHeaders(string $role = 'super_administrator'): array
{
    return ['X-Pioneer-Role' => $role];
}

function fuelEventSeedSnapshot(array $fuel = []): void
{
    $snapshot = [
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
        'fuel' => array_replace_recursive([
            'events' => [],
            'transactions' => [],
            'usageByVehicle' => [],
            'chargeEvents' => [],
            'totals' => [],
        ], $fuel),
        'telemetry' => ['assets' => []],
        'temperature' => [],
        'compliance' => [],
        'reports' => [
            'unmatchedRoutes' => [],
            'driverCongregation' => [],
        ],
        'lastSyncedAt' => now()->toIso8601String(),
    ];

    Cache::put('geotab_fleet_snapshot_v4_fresh', $snapshot, now()->addMinutes(10));
    Cache::put('geotab_fleet_snapshot_v4_stale', $snapshot, now()->addMinutes(30));
}

test('manual fuel events are stored and included in normalized fuel rows', function (): void {
    fuelEventSeedSnapshot();

    $this->withHeaders(fuelEventHeaders())->postJson('/api/fleet/fuel/events/manual', [
        'vehiclePlate' => 'DEMO-TRK-01',
        'vehicleGeotabId' => 'device-demo-01',
        'driverName' => 'Demo Driver',
        'stationName' => 'Demo Shell Station',
        'eventAt' => now()->subHour()->toIso8601String(),
        'liters' => 42.5,
        'pricePerLiter' => 68.75,
        'totalCost' => 2921.88,
        'fuelType' => 'diesel',
        'notes' => 'Receipt checked by dispatcher.',
    ])
        ->assertOk()
        ->assertJsonPath('data.vehiclePlate', 'DEMO-TRK-01')
        ->assertJsonPath('data.sourceType', 'manual')
        ->assertJsonPath('data.reviewStatus', 'confirmed')
        ->assertJsonPath('data.confidence', 'manual');

    $this->withHeaders(fuelEventHeaders())->getJson('/api/fleet/fuel/transactions')
        ->assertOk()
        ->assertJsonFragment([
            'vehiclePlate' => 'DEMO-TRK-01',
            'sourceLabel' => 'Manual Record',
            'reviewStatusLabel' => 'Confirmed',
        ]);
});

test('geotab fuel transactions are normalized as exact confirmed events', function (): void {
    fuelEventSeedSnapshot([
        'transactions' => [[
            'id' => 'gt-fuel-1',
            'sourceRecordId' => 'gt-fuel-1',
            'vehicle' => 'DEMO-TRK-02',
            'vehicleGeotabId' => 'device-demo-02',
            'station' => 'GeoTab Fuel Card Station',
            'dateTime' => now()->subMinutes(30)->toIso8601String(),
            'volumeLiters' => 38.25,
            'pricePerLiter' => 71.50,
            'cost' => 2734.88,
        ]],
    ]);

    $this->withHeaders(fuelEventHeaders())->getJson('/api/fleet/fuel/transactions')
        ->assertOk()
        ->assertJsonPath('data.0.eventType', 'confirmed_transaction')
        ->assertJsonPath('data.0.sourceType', 'geotab_transaction')
        ->assertJsonPath('data.0.reviewStatus', 'confirmed')
        ->assertJsonPath('data.0.confidence', 'exact')
        ->assertJsonPath('data.0.sourceLabel', 'Exact GeoTab Transaction');
});

test('native fuel events do not duplicate active geotab source records', function (): void {
    fuelEventSeedSnapshot([
        'transactions' => [[
            'id' => 'gt-fuel-duplicate',
            'sourceRecordId' => 'gt-fuel-duplicate',
            'vehicle' => 'DEMO-TRK-03',
            'station' => 'GeoTab Station',
            'dateTime' => now()->subMinutes(20)->toIso8601String(),
            'volumeLiters' => 22.0,
            'cost' => 1540.0,
        ]],
    ]);

    FuelEvent::query()->create([
        'vehicle_plate' => 'DEMO-TRK-03',
        'event_type' => 'confirmed_transaction',
        'source_type' => 'geotab_transaction',
        'source_record_id' => 'gt-fuel-duplicate',
        'review_status' => 'confirmed',
        'confidence' => 'exact',
        'station_name' => 'Duplicate Native Station',
        'event_at' => now()->subMinutes(20),
        'liters' => 22.0,
        'total_cost' => 1540.0,
    ]);

    $rows = $this->withHeaders(fuelEventHeaders())->getJson('/api/fleet/fuel/transactions')
        ->assertOk()
        ->json('data');

    expect($rows)->toHaveCount(1)
        ->and($rows[0]['station'])->toBe('GeoTab Station');
});

test('suggested station fuel events can be confirmed or rejected', function (): void {
    fuelEventSeedSnapshot();

    $event = FuelEvent::query()->create([
        'vehicle_plate' => 'DEMO-TRK-04',
        'event_type' => 'suggested_station_stop',
        'source_type' => 'station_stop',
        'source_record_id' => 'station-stop-1',
        'review_status' => 'needs_review',
        'confidence' => 'likely',
        'station_name' => 'Likely Caltex Stop',
        'event_at' => now()->subMinutes(15),
        'liters' => 30.0,
        'price_per_liter' => 70.0,
        'total_cost' => 2100.0,
    ]);

    $this->withHeaders(fuelEventHeaders())->postJson("/api/fleet/fuel/events/{$event->id}/confirm", [
        'notes' => 'Receipt matched station stop.',
    ])
        ->assertOk()
        ->assertJsonPath('data.reviewStatus', 'confirmed')
        ->assertJsonPath('data.reviewStatusLabel', 'Confirmed');

    $second = FuelEvent::query()->create([
        'vehicle_plate' => 'DEMO-TRK-05',
        'event_type' => 'suggested_station_stop',
        'source_type' => 'station_stop',
        'source_record_id' => 'station-stop-2',
        'review_status' => 'needs_review',
        'confidence' => 'uncertain',
        'station_name' => 'Unverified Station',
        'event_at' => now()->subMinutes(10),
        'liters' => 12.0,
        'total_cost' => 840.0,
    ]);

    $this->withHeaders(fuelEventHeaders())->postJson("/api/fleet/fuel/events/{$second->id}/reject", [
        'reason' => 'No receipt or driver confirmation.',
    ])
        ->assertOk()
        ->assertJsonPath('data.reviewStatus', 'rejected')
        ->assertJsonPath('data.reviewStatusLabel', 'Rejected');
});
