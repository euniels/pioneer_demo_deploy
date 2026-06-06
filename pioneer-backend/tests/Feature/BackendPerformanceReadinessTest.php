<?php

use Illuminate\Support\Facades\Cache;

test('performance readiness command reports cache index and timing categories', function (): void {
    Cache::put('geotab_live_snapshot_v2_fresh', [
        'lastSyncedAt' => now()->subSeconds(2)->toIso8601String(),
        'vehicles' => [],
        'trips' => [],
    ], now()->addMinute());
    Cache::put('geotab_fleet_snapshot_v4_fresh', [
        'lastSyncedAt' => now()->subSeconds(5)->toIso8601String(),
        'vehicles' => [],
        'drivers' => [],
        'trips' => [],
    ], now()->addMinute());

    $this->artisan('pioneer:performance-check')
        ->expectsOutputToContain('Live cache readiness')
        ->expectsOutputToContain('Fleet snapshot readiness')
        ->expectsOutputToContain('Endpoint timing metadata')
        ->expectsOutputToContain('Cache-first live contract')
        ->assertExitCode(0);
});
