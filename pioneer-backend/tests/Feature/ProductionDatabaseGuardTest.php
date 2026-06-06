<?php

use App\Providers\AppServiceProvider;
use Illuminate\Support\Facades\Log;

test('production boot logs a prominent warning when database connection is not mysql', function () {
    $this->app->detectEnvironment(fn (): string => 'production');
    config(['database.default' => 'sqlite']);

    Log::spy();

    (new AppServiceProvider($this->app))->boot();

    Log::shouldHaveReceived('warning')
        ->once()
        ->withArgs(fn (string $message, array $context): bool => str_contains($message, 'PIONEERPATH PRODUCTION DATABASE WARNING')
            && ($context['db_connection'] ?? null) === 'sqlite'
            && ($context['required_connection'] ?? null) === 'mysql');
});
