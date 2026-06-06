<?php

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\File;

test('queue check proves a sync queue can process the health probe', function (): void {
    config()->set('queue.default', 'sync');

    $this->artisan('pioneer:queue-check', ['--wait' => 0])
        ->expectsOutputToContain('queue_connection=sync')
        ->expectsOutputToContain('probe_processed=yes')
        ->assertExitCode(0);
});

test('scheduler status reports stale and fresh required commands', function (): void {
    Cache::forget('geotab_scheduler_last_run_geotab_feed_sync');
    Cache::forget('geotab_scheduler_last_run_geotab_snapshot_warm');
    Cache::forget('geotab_scheduler_last_run_geotab_writeback_process');

    $this->artisan('pioneer:scheduler-status')
        ->expectsOutputToContain('geotab:feed-sync')
        ->expectsOutputToContain('production_cron=')
        ->assertExitCode(1);

    Cache::put('geotab_scheduler_last_run_geotab_feed_sync', now()->toIso8601String(), now()->addDay());
    Cache::put('geotab_scheduler_last_run_geotab_snapshot_warm', now()->toIso8601String(), now()->addDay());
    Cache::put('geotab_scheduler_last_run_geotab_writeback_process', now()->toIso8601String(), now()->addDay());

    $this->artisan('pioneer:scheduler-status')
        ->expectsOutputToContain('Required scheduler commands are fresh.')
        ->assertExitCode(0);
});

test('demo backup marker creates a fresh non public backup marker', function (): void {
    $path = storage_path('framework/demo-backup-markers');
    File::deleteDirectory($path);
    config()->set('pioneer.backups.path', $path);

    $this->artisan('pioneer:backup-demo-mark')
        ->expectsOutputToContain('Created a demo backup marker')
        ->assertExitCode(0);

    $markers = glob($path.DIRECTORY_SEPARATOR.'pioneerpath-demo-marker-*.sql.gz') ?: [];
    expect($markers)->toHaveCount(1);

    $this->artisan('pioneer:backup-check')
        ->assertExitCode(0);

    File::deleteDirectory($path);
});
