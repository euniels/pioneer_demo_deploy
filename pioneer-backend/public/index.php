<?php

use Illuminate\Foundation\Application;
use Illuminate\Http\Request;

define('LARAVEL_START', microtime(true));

// Set conservative runtime limits to help prevent memory/execution overruns.
// For CLI (artisan) we allow longer-running processes; for local web requests
// set a modest memory limit and execution time so failing external calls
// don't take down the process silently.
$sapi = php_sapi_name();
if ($sapi === 'cli') {
    @ini_set('memory_limit', '512M');
    @ini_set('max_execution_time', '0');
} else {
    $appEnv = getenv('APP_ENV') ?: ($_SERVER['APP_ENV'] ?? '');
    $appDebug = getenv('APP_DEBUG') ?: ($_SERVER['APP_DEBUG'] ?? '');
    if ($appEnv === 'local' || $appDebug === '1' || $appDebug === 'true') {
        @ini_set('memory_limit', '256M');
        @ini_set('max_execution_time', '60');
        @set_time_limit(60);
    }
}

// Determine if the application is in maintenance mode...
if (file_exists($maintenance = __DIR__.'/../storage/framework/maintenance.php')) {
    require $maintenance;
}

// Register the Composer autoloader...
require __DIR__.'/../vendor/autoload.php';

// Bootstrap Laravel and handle the request...
/** @var Application $app */
$app = require_once __DIR__.'/../bootstrap/app.php';

$app->handleRequest(Request::capture());
