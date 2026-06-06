<?php

use App\Models\GpsLog;
use App\Models\MaintenanceHistory;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Cache;

uses(RefreshDatabase::class);

beforeEach(function () {
    Carbon::setTestNow(Carbon::parse('2026-05-07T08:00:00Z'));
    Cache::flush();
});

afterEach(function () {
    Carbon::setTestNow();
    Cache::flush();
});

function cachePredictiveSnapshot(array $overrides = []): void
{
    Cache::put('geotab_fleet_snapshot_v4_fresh', array_replace_recursive([
        'lastSyncedAt' => now()->toIso8601String(),
        'vehicles' => [
            ['geotabId' => 'device-1', 'plate' => 'PTR-001', 'driver' => 'Ada Cruz', 'odometerKm' => 18000],
            ['geotabId' => 'device-2', 'plate' => 'PTR-002', 'driver' => 'Ben Santos', 'odometerKm' => 42000],
        ],
        'drivers' => [
            ['name' => 'Ada Cruz'],
            ['name' => 'Ben Santos'],
        ],
        'trips' => [
            ['tripId' => 'trip-a', 'routeName' => 'Warehouse to Client', 'driver' => 'Ada Cruz', 'vehicle' => 'PTR-001', 'startedAt' => '2026-05-02T08:00:00Z', 'distanceKm' => 24, 'plannedDistanceKm' => 1, 'arrivalState' => 'on_time'],
            ['tripId' => 'trip-b', 'routeName' => 'Warehouse to Client', 'driver' => 'Ada Cruz', 'vehicle' => 'PTR-001', 'startedAt' => '2026-05-03T08:00:00Z', 'distanceKm' => 20, 'plannedDistanceKm' => 1, 'arrivalState' => 'on_time'],
            ['tripId' => 'trip-c', 'routeName' => 'Warehouse to Client', 'driver' => 'Ben Santos', 'vehicle' => 'PTR-002', 'startedAt' => '2026-05-04T08:00:00Z', 'distanceKm' => 18, 'plannedDistanceKm' => 1, 'arrivalState' => 'late'],
            ['tripId' => 'trip-d', 'routeName' => 'Warehouse to Client', 'driver' => 'Ben Santos', 'vehicle' => 'PTR-002', 'startedAt' => '2026-05-05T08:00:00Z', 'distanceKm' => 22, 'plannedDistanceKm' => 1, 'arrivalState' => 'late'],
            ['tripId' => 'trip-e', 'routeName' => 'Depot to North', 'driver' => 'Ada Cruz', 'vehicle' => 'PTR-001', 'startedAt' => '2026-04-20T08:00:00Z', 'distanceKm' => 12, 'plannedDistanceKm' => 12, 'arrivalState' => 'on_time'],
        ],
        'billings' => [
            ['date' => '2026-05-01', 'fuelCost' => 1000],
            ['date' => '2026-05-06', 'fuelCost' => 2000],
            ['date' => '2026-04-29', 'fuelCost' => 500],
        ],
        'fuel' => [
            'transactions' => [
                ['dateTime' => '2026-05-02T10:00:00Z', 'cost' => 1500],
                ['dateTime' => '2026-05-03T10:00:00Z', 'cost' => 1700],
            ],
        ],
        'maintenanceFaults' => [
            ['plate' => 'PTR-002', 'code' => 'P0100'],
            ['plate' => 'PTR-002', 'code' => 'P0200'],
        ],
    ], $overrides), now()->addMinutes(10));
}

function seedPredictiveMaintenanceHistory(): void
{
    MaintenanceHistory::query()->create([
        'vehicle_plate' => 'PTR-001',
        'type' => 'PMS',
        'description' => 'Initial service',
        'recorded_at' => '2026-01-01T00:00:00Z',
        'meta' => ['odometerKm' => 10000],
    ]);
    MaintenanceHistory::query()->create([
        'vehicle_plate' => 'PTR-001',
        'type' => 'PMS',
        'description' => 'Follow-up service',
        'recorded_at' => '2026-04-01T00:00:00Z',
        'meta' => ['odometerKm' => 15000],
    ]);
    MaintenanceHistory::query()->create([
        'vehicle_plate' => 'PTR-002',
        'type' => 'PMS',
        'description' => 'Overdue service',
        'recorded_at' => '2026-04-20T00:00:00Z',
        'next_due_at' => '2026-05-05T00:00:00Z',
        'meta' => ['odometerKm' => 40000],
    ]);
}

function seedRouteDistanceLogs(): void
{
    foreach (['trip-a', 'trip-b', 'trip-c', 'trip-d'] as $tripId) {
        GpsLog::query()->create([
            'trip_id' => $tripId,
            'geotab_log_id' => $tripId.'-1',
            'device_geotab_id' => 'device-1',
            'latitude' => 14.0000000,
            'longitude' => 121.0000000,
            'recorded_at' => '2026-05-02T08:00:00Z',
        ]);
        GpsLog::query()->create([
            'trip_id' => $tripId,
            'geotab_log_id' => $tripId.'-2',
            'device_geotab_id' => 'device-1',
            'latitude' => 14.0200000,
            'longitude' => 121.0000000,
            'recorded_at' => '2026-05-02T08:10:00Z',
        ]);
    }
}

test('predictive intelligence endpoints return cached payloads with timing headers', function () {
    cachePredictiveSnapshot();
    seedPredictiveMaintenanceHistory();
    seedRouteDistanceLogs();

    $this->getJson('/api/fleet/maintenance/predictions')
        ->assertOk()
        ->assertHeader('X-Pioneer-Elapsed-Ms')
        ->assertJsonPath('data.cacheTtlSeconds', 3600)
        ->assertJsonPath('data.topUrgent.0.plate', 'PTR-002');

    $this->getJson('/api/fleet/analytics/driver-performance')
        ->assertOk()
        ->assertJsonPath('data.cacheTtlSeconds', 600)
        ->assertJsonPath('data.topDrivers.0.driver', 'Ada Cruz')
        ->assertJsonStructure(['data' => ['rankedDrivers', 'topDrivers', 'bottomDrivers']]);

    $this->getJson('/api/fleet/analytics/vehicle-health')
        ->assertOk()
        ->assertJsonPath('data.cacheTtlSeconds', 600)
        ->assertJsonPath('data.vehicles.0.plate', 'PTR-002');

    $this->getJson('/api/fleet/analytics/route-efficiency')
        ->assertOk()
        ->assertJsonPath('data.cacheTtlSeconds', 600)
        ->assertJsonPath('data.routes.0.flagged', true);

    $this->getJson('/api/fleet/analytics/trip-forecast')
        ->assertOk()
        ->assertJsonPath('data.cacheTtlSeconds', 3600)
        ->assertJsonCount(7, 'data.forecast');

    $firstFuel = $this->getJson('/api/fleet/analytics/fuel-trend')
        ->assertOk()
        ->assertJsonPath('data.cacheTtlSeconds', 600)
        ->assertJsonStructure(['data' => ['trendDirection', 'trendPercent', 'sparkline']])
        ->json('data.thisWeekCost');

    cachePredictiveSnapshot([
        'billings' => [
            ['date' => '2026-05-06', 'fuelCost' => 99999],
        ],
    ]);

    $secondFuel = $this->getJson('/api/fleet/analytics/fuel-trend')
        ->assertOk()
        ->json('data.thisWeekCost');

    expect($secondFuel)->toBe($firstFuel);
});

test('dashboard summary surfaces top three urgent maintenance predictions', function () {
    cachePredictiveSnapshot();
    seedPredictiveMaintenanceHistory();

    $this->getJson('/api/fleet/dashboard/summary')
        ->assertOk()
        ->assertJsonPath('data.predictiveMaintenance.0.plate', 'PTR-002')
        ->assertJsonCount(2, 'data.predictiveMaintenance');
});

test('maintenance predictions include local maintenance history even without geotab vehicles', function () {
    cachePredictiveSnapshot(['vehicles' => []]);

    MaintenanceHistory::query()->create([
        'vehicle_plate' => 'LOCAL-001',
        'type' => 'Preventive Maintenance Service',
        'description' => 'Local-only service history.',
        'recorded_at' => '2026-04-01T00:00:00Z',
        'next_due_at' => '2026-05-10T00:00:00Z',
        'odometer_km' => 22000,
        'source' => 'manual',
    ]);

    $this->getJson('/api/fleet/maintenance/predictions')
        ->assertOk()
        ->assertJsonPath('data.vehicles.0.plate', 'LOCAL-001')
        ->assertJsonPath('data.vehicles.0.state', 'due_soon')
        ->assertJsonPath('data.topUrgent.0.plate', 'LOCAL-001');
});
