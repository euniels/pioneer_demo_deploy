<?php

use App\Models\GeotabFeedRow;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Cache;

uses(RefreshDatabase::class);

beforeEach(function () {
    Carbon::setTestNow(Carbon::parse('2026-04-27T12:00:00Z'));
    Cache::flush();
});

afterEach(function () {
    Carbon::setTestNow();
    Cache::flush();
});

function cacheDashboardSnapshot(array $overrides = []): void
{
    Cache::put('geotab_fleet_snapshot_v4_fresh', array_replace_recursive([
        'vehicles' => [
            ['plate' => 'PTR-001', 'driver' => 'Ada Cruz', 'status' => 'on trip'],
            ['plate' => 'PTR-002', 'driver' => 'Ben Santos', 'status' => 'idle'],
            ['plate' => 'PTR-003', 'driver' => 'Cora Lim', 'status' => 'available'],
        ],
        'drivers' => [
            ['name' => 'Ada Cruz', 'assignedVehicle' => 'PTR-001'],
            ['name' => 'Ben Santos', 'assignedVehicle' => 'PTR-002'],
        ],
        'trips' => [
            [
                'tripId' => 'TRP-TODAY-A',
                'vehicle' => 'PTR-001',
                'driver' => 'Ada Cruz',
                'distanceKm' => 120,
                'startedAt' => '2026-04-27T08:00:00Z',
                'origin' => "Warehouse&nbsp;A\u{0001}",
                'destination' => '',
                'startPoint' => ['latitude' => 14.5, 'longitude' => 121.0],
            ],
            [
                'tripId' => 'TRP-TODAY-B',
                'vehicle' => 'PTR-002',
                'driver' => 'Ben Santos',
                'distanceKm' => 45,
                'startedAt' => '2026-04-27T09:00:00Z',
                'origin' => 'North Hub',
                'destination' => 'South Hub',
            ],
            [
                'tripId' => 'TRP-OLD',
                'vehicle' => 'PTR-003',
                'driver' => 'Cora Lim',
                'distanceKm' => 80,
                'startedAt' => '2026-04-24T10:00:00Z',
                'origin' => 'Old Origin',
                'destination' => 'Old Destination',
            ],
        ],
        'billings' => [
            ['amount' => 'PHP 10,000', 'date' => '2026-04-27'],
            ['amount' => 'PHP 5,000', 'date' => '2026-04-21'],
        ],
        'telemetry' => [
            'humidityAlertAssets' => 0,
        ],
    ], $overrides), now()->addMinutes(10));
}

test('dashboard summary returns all panel payloads with zero count day buckets and route fallback text', function () {
    cacheDashboardSnapshot();

    GeotabFeedRow::query()->create([
        'type_name' => 'StatusData',
        'diagnostic_alias' => 'relativeHumidity',
        'recorded_at' => now(),
        'payload_hash' => hash('sha256', 'humidity-alert'),
        'payload' => ['data' => 90, 'alertTriggered' => true],
    ]);

    $response = $this->getJson('/api/fleet/dashboard/summary')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.cacheTtlSeconds', 120)
        ->assertJsonPath('data.fleetUtilization.activeVehiclesToday', 2)
        ->assertJsonPath('data.fleetUtilization.totalVehicles', 3)
        ->assertJsonPath('data.fleetUtilization.percentageLabel', '66.7%')
        ->assertJsonPath('data.topActiveVehicles.0.plateNumber', 'PTR-001')
        ->assertJsonPath('data.topActiveVehicles.0.distanceKmToday', 120)
        ->assertJsonPath('data.recentRevenueSummary.thisWeekLabel', 'PHP 10,000.00')
        ->assertJsonPath('data.recentRevenueSummary.lastWeekLabel', 'PHP 5,000.00')
        ->assertJsonPath('data.recentRevenueSummary.trend', 'up')
        ->assertJsonPath('data.humidityAlertCount.count', 1);

    $payload = $response->json('data');

    expect($payload['tripsThisWeek'])->toHaveCount(7)
        ->and(collect($payload['tripsThisWeek'])->pluck('count')->contains(0))->toBeTrue()
        ->and($payload['recentTrips'][0]['routeText'])->toContain('Warehouse A')
        ->and($payload['recentTrips'][0]['routeText'])->not->toContain("\u{0001}")
        ->and($payload['recentTrips'][0]['routeFallback'])->toContain('14.5000°N, 121.0000°E');
});

test('dashboard summary is cached for 120 seconds', function () {
    cacheDashboardSnapshot();

    $first = $this->getJson('/api/fleet/dashboard/summary')
        ->assertOk()
        ->json('data');

    cacheDashboardSnapshot([
        'vehicles' => [
            ['plate' => 'PTR-999', 'driver' => 'Changed', 'status' => 'on trip'],
        ],
        'trips' => [],
    ]);

    $second = $this->getJson('/api/fleet/dashboard/summary')
        ->assertOk()
        ->json('data');

    expect($second['fleetUtilization']['totalVehicles'])->toBe($first['fleetUtilization']['totalVehicles'])
        ->and($second['topActiveVehicles'][0]['plateNumber'])->toBe('PTR-001');
});
