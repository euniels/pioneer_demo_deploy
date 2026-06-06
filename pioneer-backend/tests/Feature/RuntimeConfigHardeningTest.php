<?php

test('runtime code does not read env directly outside config files', function (): void {
    $paths = [
        base_path('app'),
        base_path('routes'),
        base_path('bootstrap'),
    ];
    $violations = [];

    foreach ($paths as $path) {
        $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($path));
        foreach ($iterator as $file) {
            if (! $file->isFile() || $file->getExtension() !== 'php') {
                continue;
            }

            $contents = file_get_contents($file->getPathname()) ?: '';
            if (preg_match('/\benv\s*\(/', $contents) === 1) {
                $violations[] = str_replace(base_path().DIRECTORY_SEPARATOR, '', $file->getPathname());
            }
        }
    }

    expect($violations)->toBe([]);
});

test('geotab config exposes config cache safe runtime values', function (): void {
    expect(config('geotab'))->toHaveKeys([
        'database',
        'username',
        'password',
        'server',
        'feed_default_seed_days',
        'retry_base_ms',
        'http_feed_sync',
    ])
        ->and(config('pioneer'))->toHaveKeys([
            'frontend_url',
            'cors_allowed_origins',
            'sse_enabled',
        ])
        ->and(config('services.google_maps'))->toHaveKey('enrichment_enabled');
});

test('runtime check command reports runtime readiness categories', function (): void {
    $this->artisan('pioneer:runtime-check')
        ->expectsOutputToContain('Config cache safe GeoTab config')
        ->expectsOutputToContain('Cache store runtime')
        ->expectsOutputToContain('Scheduler snapshot warm fresh')
        ->assertExitCode(1);
});
