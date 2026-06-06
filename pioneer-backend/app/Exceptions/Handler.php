<?php

namespace App\Exceptions;

use Illuminate\Foundation\Exceptions\Handler as ExceptionHandler;
use Throwable;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

class Handler extends ExceptionHandler
{
    /**
     * A list of the exception types that are not reported.
     *
     * @var array<int, class-string<Throwable>>
     */
    protected $dontReport = [
        
    ];

    /**
     * Report or log an exception.
     *
    * @param  Throwable  $exception
     * @return void
     *
    * @throws Throwable
     */
    public function report(Throwable $exception)
    {
        // If this looks like a lost DB connection, try to reconnect so subsequent
        // requests have a fresh PDO instance.
        try {
            $message = strtolower($exception->getMessage() ?? '');
            if (strpos($message, 'server has gone away') !== false
                || strpos($message, 'gone away') !== false
                || strpos($message, 'lost connection') !== false
                || strpos($message, 'connection timed out') !== false
            ) {
                Log::warning('Detected PDO connection issue in exception handler: attempting DB::reconnect()');
                try {
                    DB::reconnect();
                    // touch the connection to force re-init
                    DB::connection()->getPdo();
                    Log::info('DB reconnect attempt completed from exception handler.');
                } catch (Throwable $e) {
                    Log::error('DB reconnect failed in exception handler: ' . $e->getMessage());
                }
            }
        } catch (Throwable $ignored) {
            // fall through to default reporting
        }

        parent::report($exception);
    }
}
