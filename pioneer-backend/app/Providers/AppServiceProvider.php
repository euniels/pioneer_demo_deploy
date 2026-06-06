<?php

namespace App\Providers;

use Illuminate\Support\Facades\Log;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        //
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        $this->protectRuntimeLimits();

        $connection = (string) config('database.default', '');

        if (! $this->app->environment(['local', 'testing']) && $connection !== 'mysql') {
            Log::warning('PIONEERPATH PRODUCTION DATABASE WARNING: non-MySQL database connection configured.', [
                'app_env' => $this->app->environment(),
                'db_connection' => $connection,
                'required_connection' => 'mysql',
                'risk' => 'SQLite is not supported for PioneerPath production feed, GPS, notification, scheduler, and write-back workloads.',
            ]);
        }
    }

    private function protectRuntimeLimits(): void
    {
        if ($this->bytesFromIniValue((string) ini_get('memory_limit')) < 268435456) {
            @ini_set('memory_limit', '256M');
        }

        if ((int) ini_get('max_execution_time') > 0 && (int) ini_get('max_execution_time') < 60) {
            @ini_set('max_execution_time', '60');
        }
    }

    private function bytesFromIniValue(string $value): int
    {
        $value = trim($value);
        if ($value === '' || $value === '-1') {
            return PHP_INT_MAX;
        }

        $unit = strtolower(substr($value, -1));
        $number = (int) $value;

        return match ($unit) {
            'g' => $number * 1024 * 1024 * 1024,
            'm' => $number * 1024 * 1024,
            'k' => $number * 1024,
            default => $number,
        };
    }
}
