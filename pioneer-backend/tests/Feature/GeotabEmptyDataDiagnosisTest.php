<?php

use App\Models\GeotabFeedCheckpoint;
use App\Models\GeotabFeedRow;
use App\Services\GeotabService;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Schema;

beforeEach(function (): void {
    Cache::flush();
    if (Schema::hasTable('geotab_feed_rows')) {
        GeotabFeedRow::query()->delete();
    }
    if (Schema::hasTable('geotab_feed_checkpoints')) {
        GeotabFeedCheckpoint::query()->delete();
    }
});

function seedGeotabFeedState(): void
{
    if (! Schema::hasTable('geotab_feed_checkpoints') || ! Schema::hasTable('geotab_feed_rows')) {
        test()->markTestSkipped('GeoTab feed tables are not available.');
    }

    GeotabFeedCheckpoint::query()->create([
        'type_name' => 'LogRecord',
        'cursor' => 'cursor-1',
        'seeded_at' => now(),
        'last_success_at' => now(),
        'last_row_count' => 1,
        'consecutive_failures' => 0,
    ]);
    GeotabFeedRow::query()->create([
        'type_name' => 'LogRecord',
        'geotab_id' => 'log-1',
        'feed_cursor' => 'cursor-1',
        'recorded_at' => now(),
        'payload_hash' => hash('sha256', 'log-1'),
        'payload' => ['id' => 'log-1'],
    ]);
}

function markGeotabSchedulerFresh(): void
{
    Cache::put('geotab_scheduler_last_run_geotab_feed_sync', now()->toIso8601String(), now()->addDay());
    Cache::put('geotab_scheduler_last_run_geotab_snapshot_warm', now()->toIso8601String(), now()->addDay());
    Cache::put('geotab_scheduler_last_run_geotab_warm_session', now()->toIso8601String(), now()->addDay());
}

test('geotab health explains missing credentials', function (): void {
    $this->app->bind(GeotabService::class, fn (): GeotabService => new class extends GeotabService
    {
        public function isConfigured(): bool
        {
            return false;
        }

        public function diagnostics(): array
        {
            return [
                'configured' => false,
                'credentials' => ['database' => false, 'username' => false, 'password' => false, 'server' => false],
                'endpoint' => 'https://my.geotab.com/apiv1',
                'sessionCached' => false,
                'circuit' => ['open' => false],
            ];
        }
    });

    $this->getJson('/api/fleet/geotab/health')
        ->assertOk()
        ->assertJsonPath('data.emptyDataDiagnosis.status', 'blocked')
        ->assertJsonPath('data.emptyDataDiagnosis.primaryReason', 'not_configured');
});

test('geotab health reports feed seed requirement before cache diagnosis', function (): void {
    markGeotabSchedulerFresh();

    $this->getJson('/api/fleet/geotab/health')
        ->assertOk()
        ->assertJsonPath('data.emptyDataDiagnosis.status', 'blocked')
        ->assertJsonPath('data.emptyDataDiagnosis.primaryReason', 'feed_not_seeded');
});

test('geotab health reports stale scheduler after seeded feed exists', function (): void {
    seedGeotabFeedState();
    Cache::put('geotab_scheduler_last_run_geotab_feed_sync', now()->subHour()->toIso8601String(), now()->addDay());
    Cache::put('geotab_scheduler_last_run_geotab_snapshot_warm', now()->subHour()->toIso8601String(), now()->addDay());
    Cache::put('geotab_scheduler_last_run_geotab_warm_session', now()->subHour()->toIso8601String(), now()->addDay());

    $this->getJson('/api/fleet/geotab/health')
        ->assertOk()
        ->assertJsonPath('data.emptyDataDiagnosis.status', 'warning')
        ->assertJsonPath('data.emptyDataDiagnosis.primaryReason', 'scheduler_not_running');
});

test('geotab health reports missing snapshot cache after feed and scheduler are healthy', function (): void {
    seedGeotabFeedState();
    markGeotabSchedulerFresh();

    $this->getJson('/api/fleet/geotab/health')
        ->assertOk()
        ->assertJsonPath('data.emptyDataDiagnosis.status', 'warning')
        ->assertJsonPath('data.emptyDataDiagnosis.primaryReason', 'snapshot_not_warmed');
});

test('geotab health reports ok when cache feed and scheduler have operational data', function (): void {
    seedGeotabFeedState();
    markGeotabSchedulerFresh();
    Cache::put('geotab_fleet_snapshot_v4_fresh', [
        'vehicles' => [['geotabId' => 'device-1']],
        'drivers' => [['geotabId' => 'driver-1']],
        'trips' => [],
        'routes' => [],
    ], now()->addMinute());
    Cache::put('geotab_live_snapshot_v2_fresh', [
        'vehicles' => [['geotabId' => 'device-1']],
    ], now()->addMinute());

    $this->getJson('/api/fleet/geotab/health')
        ->assertOk()
        ->assertJsonPath('data.emptyDataDiagnosis.status', 'ok')
        ->assertJsonPath('data.emptyDataDiagnosis.primaryReason', 'ok');
});

test('geotab diagnose command prints the primary reason', function (): void {
    $this->artisan('geotab:diagnose')
        ->expectsOutputToContain('PioneerPath GeoTab diagnosis')
        ->expectsOutputToContain('Primary reason: feed_not_seeded')
        ->assertExitCode(1);
});
