<?php

use App\Services\GeotabService;
use Carbon\CarbonInterface;
use Illuminate\Support\Facades\Cache;

function bindFailingGeotabService(): void
{
    app()->bind(GeotabService::class, fn (): GeotabService => new class extends GeotabService
    {
        public function authenticate(): string
        {
            throw new RuntimeException('GeoTab should not be called by live HTTP endpoints.');
        }

        public function call(string $method, array $params = []): mixed
        {
            throw new RuntimeException('GeoTab call should not run for '.$method.'.');
        }

        public function getEntities(
            string $typeName,
            array $search = [],
            ?int $resultsLimit = null,
            array $extraParams = [],
        ): array {
            throw new RuntimeException('GeoTab getEntities should not run for '.$typeName.'.');
        }

        public function getFeed(
            string $typeName,
            ?string $fromVersion = null,
            array $search = [],
            ?int $resultsLimit = null,
            ?CarbonInterface $fromDate = null,
            ?array $propertySelector = null,
        ): array {
            throw new RuntimeException('GeoTab getFeed should not run for '.$typeName.'.');
        }
    });
}

test('live endpoint serves warmed live cache without direct geotab calls', function (): void {
    bindFailingGeotabService();
    Cache::put('geotab_live_snapshot_v2_fresh', [
        'lastSyncedAt' => now()->subSeconds(3)->toIso8601String(),
        'movingVehicles' => 1,
        'vehicles' => [
            ['geotabId' => 'device-1', 'plate' => 'PTC-001', 'speed' => 32],
        ],
        'trips' => [],
    ], now()->addMinute());

    $this->getJson('/api/fleet/live')
        ->assertOk()
        ->assertHeader('X-Pioneer-Elapsed-Ms')
        ->assertHeader('X-Pioneer-Served-From', 'snapshot')
        ->assertJsonStructure(['meta' => ['elapsedMs', 'servedFrom', 'snapshotAgeSeconds']])
        ->assertJsonPath('data.movingVehicles', 1)
        ->assertJsonPath('meta.servedFrom', 'snapshot')
        ->assertJsonPath('meta.geotabAvailable', true);
});

test('summary live endpoint serves empty cache fallback without direct geotab calls', function (): void {
    bindFailingGeotabService();

    $this->getJson('/api/fleet/summary/live')
        ->assertOk()
        ->assertHeader('X-Pioneer-Elapsed-Ms')
        ->assertHeader('X-Pioneer-Served-From', 'stale_snapshot')
        ->assertJsonStructure(['meta' => ['elapsedMs', 'servedFrom', 'snapshotAgeSeconds']])
        ->assertJsonPath('data.stale', true)
        ->assertJsonPath('data.geotabReason', 'live_snapshot_unavailable')
        ->assertJsonPath('meta.servedFrom', 'stale_snapshot')
        ->assertJsonPath('meta.geotabAvailable', false);
});

test('fleet summary endpoint serves warmed snapshot cache without direct geotab calls', function (): void {
    bindFailingGeotabService();
    Cache::put('geotab_fleet_snapshot_v4_fresh', [
        'lastSyncedAt' => now()->subSeconds(10)->toIso8601String(),
        'vehicles' => [
            ['geotabId' => 'device-1', 'plate' => 'PTC-001'],
        ],
        'drivers' => [],
        'trips' => [],
        'routes' => [],
        'dashboard' => [],
    ], now()->addMinute());

    $this->getJson('/api/fleet/summary')
        ->assertOk()
        ->assertHeader('X-Pioneer-Elapsed-Ms')
        ->assertHeader('X-Pioneer-Served-From', 'snapshot')
        ->assertJsonStructure(['meta' => ['elapsedMs', 'servedFrom', 'snapshotAgeSeconds']])
        ->assertJsonCount(1, 'data.vehicles')
        ->assertJsonPath('meta.servedFrom', 'snapshot')
        ->assertJsonPath('meta.geotabAvailable', true);
});
