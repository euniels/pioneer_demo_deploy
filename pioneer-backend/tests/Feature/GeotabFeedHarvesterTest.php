<?php

use App\Models\GeotabFeedCheckpoint;
use App\Models\GeotabFeedRow;
use App\Models\GpsLog;
use App\Services\GeotabFeedHarvester;
use App\Services\GeotabService;
use Carbon\CarbonInterface;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Carbon;

uses(RefreshDatabase::class);

test('feed harvester seeds with fromDate once and then advances with fromVersion', function () {
    $geotab = new class extends GeotabService
    {
        public array $calls = [];

        public function isConfigured(): bool
        {
            return true;
        }

        public function getFeed(
            string $typeName,
            ?string $fromVersion = null,
            array $search = [],
            ?int $resultsLimit = null,
            ?CarbonInterface $fromDate = null,
            ?array $propertySelector = null,
        ): array {
            $this->calls[] = compact('typeName', 'fromVersion', 'search', 'resultsLimit', 'fromDate');

            return [
                'toVersion' => count($this->calls) === 1 ? 'version-1' : 'version-2',
                'data' => [[
                    'id' => 'log-'.count($this->calls),
                    'device' => ['id' => 'device-1'],
                    'dateTime' => '2026-04-20T10:00:00Z',
                    'latitude' => 14.5995,
                    'longitude' => 120.9842,
                    'speed' => 32,
                ]],
            ];
        }
    };

    $harvester = new GeotabFeedHarvester($geotab);

    $first = $harvester->sync('LogRecord', 1000, null, [
        'seedFrom' => Carbon::parse('2026-04-01T00:00:00Z'),
    ]);
    $second = $harvester->sync('LogRecord', 1000);

    expect($first['seeded'])->toBeTrue()
        ->and($second['seeded'])->toBeFalse()
        ->and($geotab->calls[0]['fromVersion'])->toBeNull()
        ->and($geotab->calls[0]['fromDate'])->not->toBeNull()
        ->and($geotab->calls[1]['fromVersion'])->toBe('version-1')
        ->and($geotab->calls[1]['fromDate'])->toBeNull();

    $checkpoint = GeotabFeedCheckpoint::query()->where('type_name', 'LogRecord')->first();
    expect($checkpoint)->not->toBeNull()
        ->and($checkpoint->cursor)->toBe('version-2')
        ->and($checkpoint->seeded_at)->not->toBeNull()
        ->and($checkpoint->last_row_count)->toBe(1)
        ->and(GeotabFeedRow::query()->where('type_name', 'LogRecord')->count())->toBe(2)
        ->and(GpsLog::query()->count())->toBe(2);
});

test('feed seed command defaults to the 30 day production window', function () {
    Carbon::setTestNow(Carbon::parse('2026-04-26T12:00:00Z'));

    $geotab = new class extends GeotabService
    {
        public ?CarbonInterface $seedFrom = null;

        public function getFeed(
            string $typeName,
            ?string $fromVersion = null,
            array $search = [],
            ?int $resultsLimit = null,
            ?CarbonInterface $fromDate = null,
            ?array $propertySelector = null,
        ): array {
            $this->seedFrom = $fromDate;

            return [
                'toVersion' => 'version-'.$typeName,
                'data' => [],
            ];
        }
    };

    app()->instance(GeotabService::class, $geotab);

    $this->artisan('geotab:feed-seed')
        ->expectsOutput('No --from date supplied; seeding from 2026-03-27 using the 30-day production default.')
        ->assertExitCode(0);

    expect($geotab->seedFrom?->toDateString())->toBe('2026-03-27');

    Carbon::setTestNow();
});

test('feed harvester records failure metadata without losing the previous cursor', function () {
    $geotab = new class extends GeotabService
    {
        public function getFeed(
            string $typeName,
            ?string $fromVersion = null,
            array $search = [],
            ?int $resultsLimit = null,
            ?CarbonInterface $fromDate = null,
            ?array $propertySelector = null,
        ): array {
            throw new RuntimeException('Geotab error: OverLimitException');
        }
    };

    GeotabFeedCheckpoint::query()->create([
        'type_name' => 'Trip',
        'cursor' => 'version-ok',
        'seeded_at' => now(),
        'seed_from' => now()->subDay(),
    ]);

    $result = (new GeotabFeedHarvester($geotab))->sync('Trip', 200);

    $checkpoint = GeotabFeedCheckpoint::query()->where('type_name', 'Trip')->first();
    expect($result['error'])->toContain('OverLimitException')
        ->and($checkpoint->cursor)->toBe('version-ok')
        ->and($checkpoint->last_error)->toContain('OverLimitException')
        ->and($checkpoint->consecutive_failures)->toBe(1);
});

test('feed prune removes raw operational rows outside the retention window', function () {
    GeotabFeedRow::query()->create([
        'type_name' => 'StatusData',
        'payload_hash' => hash('sha256', 'old-status'),
        'recorded_at' => now()->subDays(40),
        'payload' => ['id' => 'old-status'],
    ]);
    GeotabFeedRow::query()->create([
        'type_name' => 'StatusData',
        'payload_hash' => hash('sha256', 'new-status'),
        'recorded_at' => now()->subDay(),
        'payload' => ['id' => 'new-status'],
    ]);
    GpsLog::query()->create([
        'trip_id' => 'TRP-OLD',
        'geotab_log_id' => 'old-log',
        'device_geotab_id' => 'device-1',
        'latitude' => 14.1,
        'longitude' => 121.1,
        'speed' => 0,
        'recorded_at' => now()->subDays(40),
    ]);

    $result = (new GeotabFeedHarvester(app(GeotabService::class)))->prune(30);

    expect($result['deleted']['geotab_feed_rows'])->toBe(1)
        ->and($result['deleted']['gps_logs'])->toBe(1)
        ->and(GeotabFeedRow::query()->count())->toBe(1)
        ->and(GpsLog::query()->count())->toBe(0);
});

test('geotab health endpoint reports checkpoint status and local row counts', function () {
    GeotabFeedCheckpoint::query()->create([
        'type_name' => 'LogRecord',
        'cursor' => 'version-1',
        'seeded_at' => now(),
        'seed_from' => now()->subDays(3),
        'last_success_at' => now(),
        'last_row_count' => 2,
    ]);

    $response = $this->getJson('/api/fleet/geotab/health')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.feeds.0.typeName', 'LogRecord')
        ->assertJsonPath('data.feeds.0.type_name', 'LogRecord')
        ->assertJsonPath('data.feeds.0.seeded', true)
        ->assertJsonPath('data.feeds.0.last_success', now()->toIso8601String())
        ->assertJsonPath('data.feeds.0.feed_lag_seconds', 0)
        ->assertJsonPath('data.feeds.0.row_count', 2)
        ->assertJsonPath('data.rowCounts.gpsLogs', 0);

    expect($response->json('data'))->toHaveKeys(['credentials_configured', 'session_cached']);
});

test('geotab health endpoint exposes failed feed metadata', function () {
    GeotabFeedCheckpoint::query()->create([
        'type_name' => 'StatusData',
        'cursor' => 'version-failed',
        'seeded_at' => now()->subHour(),
        'seed_from' => now()->subDays(30),
        'last_error_at' => now(),
        'last_error' => 'Geotab error: OverLimitException',
        'consecutive_failures' => 3,
    ]);

    $this->getJson('/api/fleet/geotab/health')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.feeds.0.typeName', 'StatusData')
        ->assertJsonPath('data.feeds.0.lastError', 'Geotab error: OverLimitException')
        ->assertJsonPath('data.feeds.0.last_error', 'Geotab error: OverLimitException')
        ->assertJsonPath('data.feeds.0.consecutiveFailures', 3)
        ->assertJsonPath('data.feeds.0.consecutive_failures', 3);
});
