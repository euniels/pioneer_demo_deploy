<?php

use App\Http\Middleware\ApiRateLimitMiddleware;
use App\Http\Middleware\ApiSecurityHeaders;
use App\Http\Middleware\CorsMiddleware;
use App\Http\Middleware\DatabaseReconnectMiddleware;
use App\Http\Middleware\FleetCrudPermissionMiddleware;
use App\Http\Middleware\OptimizeFleetApiResponses;
use App\Http\Middleware\SanitizeApiInputMiddleware;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        api: __DIR__.'/../routes/api.php',
        web: __DIR__.'/../routes/web.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
    )
    ->withSchedule(function (Schedule $schedule): void {
        $schedule->command('geotab:warm-session')
            ->everyTenMinutes()
            ->withoutOverlapping(10);

        $schedule->command('geotab:snapshot-warm')
            ->everyMinute()
            ->withoutOverlapping(5);

        $schedule->command('geotab:feed-sync')
            ->everyTwoMinutes()
            ->withoutOverlapping(5);

        $schedule->command('geotab:writeback-process --limit=10')
            ->everyMinute()
            ->withoutOverlapping(5);

        $schedule->command('geotab:feed-prune')
            ->dailyAt('02:00')
            ->withoutOverlapping(60);
    })
    ->withMiddleware(function (Middleware $middleware): void {
        $middleware->append([
            CorsMiddleware::class,
            DatabaseReconnectMiddleware::class,
            ApiSecurityHeaders::class,
            SanitizeApiInputMiddleware::class,
            FleetCrudPermissionMiddleware::class,
            ApiRateLimitMiddleware::class,
            OptimizeFleetApiResponses::class,
        ]);
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        //
    })->create();
