<?php

use App\Models\GpsLog;
use App\Services\GeotabService;
use Carbon\CarbonInterface;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;

uses(RefreshDatabase::class);

beforeEach(function () {
    Cache::flush();
    config(['services.google_maps.server_key' => '']);
});

test('trip map draws from gps logs matched by trip id', function () {
    putTripMapSnapshot('TRP-LOCAL', 'device-local');
    createGpsLog('trip-local-1', 'TRP-LOCAL', 'device-local', 14.5995, 120.9842, '2026-04-20T10:05:00Z');
    createGpsLog('trip-local-2', 'TRP-LOCAL', 'device-local', 14.6010, 120.9860, '2026-04-20T10:20:00Z');

    $this->getJson('/api/fleet/trips/TRP-LOCAL/map')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.routeAvailable', true)
        ->assertJsonPath('data.routeSource', 'gps_logs_trip_id')
        ->assertJsonCount(2, 'data.actualTrail');
});

test('completed trip map snaps actual gps trail through google roads api when configured', function () {
    config(['services.google_maps.server_key' => 'server-test-key']);
    putTripMapSnapshot('TRP-ROADS', 'device-roads');
    createGpsLog('roads-1', 'TRP-ROADS', 'device-roads', 14.5995, 120.9842, '2026-04-20T10:05:00Z');
    createGpsLog('roads-2', 'TRP-ROADS', 'device-roads', 14.6010, 120.9860, '2026-04-20T10:20:00Z');

    Http::fake([
        'roads.googleapis.com/v1/snapToRoads*' => Http::response([
            'snappedPoints' => [
                ['location' => ['latitude' => 14.5996, 'longitude' => 120.9843], 'placeId' => 'place-a'],
                ['location' => ['latitude' => 14.6003, 'longitude' => 120.9851], 'placeId' => 'place-b'],
                ['location' => ['latitude' => 14.6011, 'longitude' => 120.9861], 'placeId' => 'place-c'],
            ],
        ]),
    ]);

    $this->getJson('/api/fleet/trips/TRP-ROADS/map')
        ->assertOk()
        ->assertJsonPath('data.routeSource', 'google_roads_snap_to_roads')
        ->assertJsonPath('data.snapToRoads.snapped', true)
        ->assertJsonPath('data.rawGpsPointCount', 2)
        ->assertJsonCount(3, 'data.actualTrail');

    Http::assertSentCount(1);
});

test('trip map falls back to gps logs matched by device and time window', function () {
    putTripMapSnapshot('TRP-WINDOW', 'device-window');
    createGpsLog('window-1', null, 'device-window', 14.6100, 120.9900, '2026-04-20T10:08:00Z');
    createGpsLog('window-2', null, 'device-window', 14.6200, 121.0000, '2026-04-20T10:24:00Z');

    $this->getJson('/api/fleet/trips/TRP-WINDOW/map')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.routeAvailable', true)
        ->assertJsonPath('data.routeSource', 'gps_logs_device_time_window')
        ->assertJsonCount(2, 'data.actualTrail');
});

test('trip map falls back to direct geotab log records when local gps logs are missing', function () {
    putTripMapSnapshot('TRP-GEOTAB', 'device-geotab');

    $geotab = new class extends GeotabService
    {
        public function getGpsTrail(
            string $deviceId,
            int $limit = 100,
            ?CarbonInterface $from = null,
            ?CarbonInterface $to = null,
        ): array {
            return [
                [
                    'id' => 'geotab-log-1',
                    'device' => ['id' => $deviceId],
                    'latitude' => 14.6300,
                    'longitude' => 121.0100,
                    'speed' => 35,
                    'dateTime' => '2026-04-20T10:10:00Z',
                ],
                [
                    'id' => 'geotab-log-2',
                    'device' => ['id' => $deviceId],
                    'latitude' => 14.6400,
                    'longitude' => 121.0200,
                    'speed' => 42,
                    'dateTime' => '2026-04-20T10:30:00Z',
                ],
            ];
        }
    };
    app()->instance(GeotabService::class, $geotab);

    $this->getJson('/api/fleet/trips/TRP-GEOTAB/map')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.routeAvailable', true)
        ->assertJsonPath('data.routeSource', 'geotab_get_logrecord')
        ->assertJsonCount(2, 'data.actualTrail');

    expect(GpsLog::query()->where('trip_id', 'TRP-GEOTAB')->count())->toBe(2);
});

test('trip map falls back to planned start and destination when gps trail is sparse', function () {
    putTripMapSnapshot('TRP-SPARSE', 'device-sparse');
    createGpsLog('sparse-1', 'TRP-SPARSE', 'device-sparse', 14.6500, 121.0300, '2026-04-20T10:15:00Z');

    $geotab = new class extends GeotabService
    {
        public function getGpsTrail(
            string $deviceId,
            int $limit = 100,
            ?CarbonInterface $from = null,
            ?CarbonInterface $to = null,
        ): array {
            return [];
        }
    };
    app()->instance(GeotabService::class, $geotab);

    $this->getJson('/api/fleet/trips/TRP-SPARSE/map')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.routeAvailable', true)
        ->assertJsonPath('data.actualRouteAvailable', false)
        ->assertJsonPath('data.plannedRouteAvailable', true)
        ->assertJsonPath('data.routeSource', 'gps_logs_device_time_window')
        ->assertJsonCount(1, 'data.actualTrail')
        ->assertJsonCount(2, 'data.plannedPath');
});

test('client tracking draws route from gps logs matched by trip id', function () {
    putTripMapSnapshot('TRP-CLIENT-LOCAL', 'device-client-local');
    createGpsLog('client-local-1', 'TRP-CLIENT-LOCAL', 'device-client-local', 14.5995, 120.9842, '2026-04-20T10:05:00Z');
    createGpsLog('client-local-2', 'TRP-CLIENT-LOCAL', 'device-client-local', 14.6010, 120.9860, '2026-04-20T10:20:00Z');

    $this->getJson('/api/fleet/client-tracking/TRP-CLIENT-LOCAL')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.routeAvailable', true)
        ->assertJsonPath('data.routeSource', 'gps_logs_trip_id')
        ->assertJsonPath('data.routeMessage', 'Route points loaded')
        ->assertJsonCount(2, 'data.route');
});

test('client tracking falls back to gps logs matched by device and time window', function () {
    putTripMapSnapshot('TRP-CLIENT-WINDOW', 'device-client-window');
    createGpsLog('client-window-1', null, 'device-client-window', 14.6100, 120.9900, '2026-04-20T10:08:00Z');
    createGpsLog('client-window-2', null, 'device-client-window', 14.6200, 121.0000, '2026-04-20T10:24:00Z');

    $this->getJson('/api/fleet/client-tracking/TRP-CLIENT-WINDOW')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.routeAvailable', true)
        ->assertJsonPath('data.routeSource', 'gps_logs_device_time_window')
        ->assertJsonCount(2, 'data.route');
});

test('client tracking falls back to direct geotab logs and sanitizes route stop labels', function () {
    putTripMapSnapshot('TRP-CLIENT-GEOTAB', 'device-client-geotab', [
        'routedPlaces' => [[
            'zoneId' => 'zone-a',
            'name' => "Depot&nbsp;A\u{0001}",
            'center' => ['latitude' => 14.6300, 'longitude' => 121.0100],
            'points' => [
                ['latitude' => 14.6300, 'longitude' => 121.0100],
                ['latitude' => 14.6310, 'longitude' => 121.0110],
                ['latitude' => 14.6320, 'longitude' => 121.0120],
            ],
        ]],
    ]);

    $geotab = new class extends GeotabService
    {
        public function getGpsTrail(
            string $deviceId,
            int $limit = 100,
            ?CarbonInterface $from = null,
            ?CarbonInterface $to = null,
        ): array {
            return [
                [
                    'id' => 'client-geotab-log-1',
                    'device' => ['id' => $deviceId],
                    'latitude' => 14.6300,
                    'longitude' => 121.0100,
                    'speed' => 35,
                    'dateTime' => '2026-04-20T10:10:00Z',
                ],
                [
                    'id' => 'client-geotab-log-2',
                    'device' => ['id' => $deviceId],
                    'latitude' => 14.6400,
                    'longitude' => 121.0200,
                    'speed' => 42,
                    'dateTime' => '2026-04-20T10:30:00Z',
                ],
            ];
        }
    };
    app()->instance(GeotabService::class, $geotab);

    $this->getJson('/api/fleet/client-tracking/TRP-CLIENT-GEOTAB')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.routeAvailable', true)
        ->assertJsonPath('data.routeSource', 'geotab_get_logrecord')
        ->assertJsonPath('data.routedPlaces.0.name', 'Depot A')
        ->assertJsonPath('data.geofences.0.name', 'Depot A')
        ->assertJsonCount(2, 'data.route')
        ->assertJsonCount(1, 'data.plannedPath');

    expect(GpsLog::query()->where('trip_id', 'TRP-CLIENT-GEOTAB')->count())->toBe(2);
});

test('client tracking reports no route message when fewer than two points exist', function () {
    putTripMapSnapshot('TRP-CLIENT-SPARSE', 'device-client-sparse');

    $geotab = new class extends GeotabService
    {
        public function getGpsTrail(
            string $deviceId,
            int $limit = 100,
            ?CarbonInterface $from = null,
            ?CarbonInterface $to = null,
        ): array {
            return [];
        }
    };
    app()->instance(GeotabService::class, $geotab);

    $this->getJson('/api/fleet/client-tracking/TRP-CLIENT-SPARSE')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.routeAvailable', false)
        ->assertJsonPath('data.routeMessage', 'No route points recorded yet')
        ->assertJsonCount(0, 'data.route');
});

function putTripMapSnapshot(string $tripId, string $deviceId, array $tripOverrides = []): void
{
    Cache::put('geotab_fleet_snapshot_v4_fresh', [
        'vehicles' => [[
            'geotabId' => $deviceId,
            'plate' => 'TRK-100',
            'driver' => 'Test Driver',
            'latitude' => 14.6500,
            'longitude' => 121.0300,
            'speed' => 0,
            'bearing' => 0,
            'lastUpdated' => '2026-04-20T11:00:00Z',
        ]],
        'trips' => [[
            'tripId' => $tripId,
            'status' => 'completed',
            'deviceGeotabId' => $deviceId,
            'vehicle' => 'TRK-100',
            'driver' => 'Test Driver',
            'origin' => 'Origin',
            'destination' => 'Destination',
            'routeName' => 'Test Route',
            'startedAt' => '2026-04-20T10:00:00Z',
            'endedAt' => '2026-04-20T11:00:00Z',
            'routedPlaces' => [],
            'startPoint' => ['latitude' => 14.5995, 'longitude' => 120.9842],
            'stopPoint' => ['latitude' => 14.6500, 'longitude' => 121.0300],
            ...$tripOverrides,
        ]],
        'lastSyncedAt' => '2026-04-20T11:00:00Z',
    ], now()->addMinute());
}

function createGpsLog(
    string $geotabLogId,
    ?string $tripId,
    string $deviceId,
    float $latitude,
    float $longitude,
    string $recordedAt,
): void {
    GpsLog::query()->create([
        'trip_id' => $tripId,
        'geotab_log_id' => $geotabLogId,
        'device_geotab_id' => $deviceId,
        'latitude' => $latitude,
        'longitude' => $longitude,
        'speed' => 25,
        'recorded_at' => Carbon::parse($recordedAt),
    ]);
}
