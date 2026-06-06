<?php

test('geotab scheduled commands are registered', function () {
    $this->artisan('schedule:list')
        ->expectsOutputToContain('*/2  * * * *  php artisan geotab:feed-sync')
        ->expectsOutputToContain('*    * * * *  php artisan geotab:snapshot-warm')
        ->expectsOutputToContain('*/10 * * * *  php artisan geotab:warm-session')
        ->expectsOutputToContain('0    2 * * *  php artisan geotab:feed-prune')
        ->expectsOutputToContain('*    * * * *  php artisan geotab:writeback-process --limit=10')
        ->assertExitCode(0);
});

test('geotab scheduler cadence and overlap lock match production plan', function () {
    $appBootstrap = file_get_contents(base_path('bootstrap/app.php'));

    expect($appBootstrap)->toMatch(
        "/command\\('geotab:feed-sync'\\)\\s*->everyTwoMinutes\\(\\)\\s*->withoutOverlapping\\(5\\)/s"
    )
        ->and($appBootstrap)->toMatch(
            "/command\\('geotab:snapshot-warm'\\)\\s*->everyMinute\\(\\)\\s*->withoutOverlapping\\(5\\)/s"
        )
        ->and($appBootstrap)->toMatch(
            "/command\\('geotab:warm-session'\\)\\s*->everyTenMinutes\\(\\)\\s*->withoutOverlapping\\(10\\)/s"
        )
        ->and($appBootstrap)->toMatch(
            "/command\\('geotab:feed-prune'\\)\\s*->dailyAt\\('02:00'\\)\\s*->withoutOverlapping\\(60\\)/s"
        )
        ->and($appBootstrap)->toMatch(
            "/command\\('geotab:writeback-process --limit=10'\\)\\s*->everyMinute\\(\\)\\s*->withoutOverlapping\\(5\\)/s"
        );
});

test('geotab operator summary prints rollout commands', function () {
    $this->artisan('geotab:ops-summary')
        ->expectsOutputToContain('php artisan migrate')
        ->expectsOutputToContain('php artisan geotab:feed-seed')
        ->expectsOutputToContain('php /path/to/artisan schedule:run >> /dev/null 2>&1')
        ->assertExitCode(0);
});
