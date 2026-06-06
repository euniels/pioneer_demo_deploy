<?php

test('production gate reports security runtime and route readiness categories', function (): void {
    $this->artisan('pioneer:production-gate')
        ->expectsOutputToContain('APP_DEBUG disabled')
        ->expectsOutputToContain('APP_KEY configured')
        ->expectsOutputToContain('Redis cache configured')
        ->expectsOutputToContain('Scheduler feed sync fresh')
        ->expectsOutputToContain('GeoTab diagnosis')
        ->expectsOutputToContain('Backup freshness')
        ->expectsOutputToContain('Core API routes registered')
        ->expectsOutputToContain('Performance readiness')
        ->assertExitCode(1);
});
