<?php

use App\Models\ManualDriver;
use App\Services\GoogleMapsEnrichmentService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;

uses(RefreshDatabase::class);

beforeEach(function (): void {
    Cache::flush();
    config([
        'services.google_maps.server_key' => '',
        'services.google_maps.depot_latitude' => null,
        'services.google_maps.depot_longitude' => null,
    ]);
});

test('client tracking uses cached google distance matrix eta when configured', function (): void {
    config(['services.google_maps.server_key' => 'server-test-key']);
    ManualDriver::query()->create([
        'name' => 'Test Driver',
        'phone' => '09171234567',
        'status' => 'active',
    ]);
    putGoogleMapsTestSnapshot('TRP-ETA', 'device-eta', [
        'status' => 'dispatched',
        'cargoType' => 'Fragile',
        'totalWeightKg' => 820.5,
    ]);
    Cache::put('geotab_live_snapshot_v2_fresh', [
        'vehicles' => [[
            'geotabId' => 'device-eta',
            'plate' => 'TRK-100',
            'latitude' => 14.6500,
            'longitude' => 121.0300,
            'speed' => 15,
            'bearing' => 90,
            'lastUpdated' => '2026-04-20T11:05:00Z',
        ]],
    ], now()->addMinute());

    Http::fake([
        'https://maps.googleapis.com/maps/api/distancematrix/json*' => Http::response([
            'status' => 'OK',
            'rows' => [[
                'elements' => [[
                    'status' => 'OK',
                    'duration' => ['text' => '18 mins', 'value' => 1080],
                    'distance' => ['text' => '12.4 km', 'value' => 12400],
                ]],
            ]],
        ]),
    ]);

    $this->getJson('/api/fleet/client-tracking/TRP-ETA')
        ->assertOk()
        ->assertJsonPath('data.eta', '18 mins')
        ->assertJsonPath('data.etaSource', 'google_distance_matrix')
        ->assertJsonPath('data.etaDistance', '12.4 km')
        ->assertJsonPath('data.etaDurationSeconds', 1080)
        ->assertJsonPath('data.driverContactMasked', '09XX XXX 4567')
        ->assertJsonPath('data.cargoType', 'Fragile')
        ->assertJsonPath('data.totalWeightKg', 820.5);

    $this->getJson('/api/fleet/client-tracking/TRP-ETA')
        ->assertOk()
        ->assertJsonPath('data.eta', '18 mins');

    expect(Http::recorded()->filter(
        fn (array $record): bool => str_contains($record[0]->url(), 'maps.googleapis.com/maps/api/distancematrix/json')
    ))->toHaveCount(1);
});

test('dispatch optimize order calls google routes api and returns advisory stop order', function (): void {
    config([
        'services.google_maps.server_key' => 'server-test-key',
        'services.google_maps.depot_latitude' => 14.5995,
        'services.google_maps.depot_longitude' => 120.9842,
    ]);
    Cache::put('geotab_fleet_snapshot_v4_fresh', [
        'vehicles' => [],
        'trips' => [],
        'lastSyncedAt' => '2026-04-20T11:00:00Z',
    ], now()->addMinute());

    Http::fake([
        'https://routes.googleapis.com/directions/v2:computeRoutes' => Http::response([
            'routes' => [[
                'optimizedIntermediateWaypointIndex' => [1, 0],
                'duration' => '1800s',
                'distanceMeters' => 15000,
            ]],
        ]),
    ]);

    $this->postJson('/api/fleet/dispatch/optimize-order', [
        'trips' => [
            [
                'tripId' => 'TRP-A',
                'customer' => 'A',
                'destination' => 'Stop A',
                'stopPoint' => ['latitude' => 14.61, 'longitude' => 121.00],
            ],
            [
                'tripId' => 'TRP-B',
                'customer' => 'B',
                'destination' => 'Stop B',
                'stopPoint' => ['latitude' => 14.62, 'longitude' => 121.01],
            ],
        ],
    ])
        ->assertOk()
        ->assertJsonPath('data.advisoryOnly', true)
        ->assertJsonPath('data.optimized', true)
        ->assertJsonPath('data.stops.0.tripId', 'TRP-B')
        ->assertJsonPath('data.stops.1.tripId', 'TRP-A');

    expect(Http::recorded()->filter(
        fn (array $record): bool => str_contains($record[0]->url(), 'routes.googleapis.com/directions/v2:computeRoutes')
    ))->toHaveCount(1);
});

test('reverse geocoding uses google before geotab address fallback and caches for a day', function (): void {
    config(['services.google_maps.server_key' => 'server-test-key']);
    Http::fake([
        'https://maps.googleapis.com/maps/api/geocode/json*' => Http::response([
            'status' => 'OK',
            'results' => [[
                'formatted_address' => 'Pulo-Diezmo Road, Cabuyao, Laguna, Philippines',
                'address_components' => [
                    ['long_name' => 'Pulo-Diezmo Road', 'types' => ['route']],
                    ['long_name' => 'Cabuyao', 'types' => ['locality']],
                    ['long_name' => 'Philippines', 'types' => ['country']],
                ],
            ]],
        ]),
    ]);

    $address = app(GoogleMapsEnrichmentService::class)->reverseGeocode([
        'latitude' => 14.5995,
        'longitude' => 120.9842,
    ]);

    expect($address)
        ->toBeArray()
        ->and($address['formattedAddress'])
        ->toBe('Pulo-Diezmo Road, Cabuyao, Laguna, Philippines')
        ->and($address['source'])
        ->toBe('google_geocoding');

    app(GoogleMapsEnrichmentService::class)->reverseGeocode([
        'latitude' => 14.5995,
        'longitude' => 120.9842,
    ]);

    Http::assertSent(fn ($request): bool => str_contains($request->url(), 'maps.googleapis.com/maps/api/geocode/json'));
    expect(Http::recorded()->filter(
        fn (array $record): bool => str_contains($record[0]->url(), 'maps.googleapis.com/maps/api/geocode/json')
    ))->toHaveCount(1);
});

function putGoogleMapsTestSnapshot(string $tripId, string $deviceId, array $tripOverrides = []): void
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
        'dashboard' => [],
        'drivers' => [],
        'routes' => [],
        'zones' => [],
        'billings' => [],
        'notifications' => [],
        'lastSyncedAt' => '2026-04-20T11:00:00Z',
    ], now()->addMinute());
}
