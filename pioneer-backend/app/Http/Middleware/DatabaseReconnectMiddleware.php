<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use PDOException;
use Symfony\Component\HttpFoundation\Response;

class DatabaseReconnectMiddleware
{
    public function handle(Request $request, Closure $next): Response
    {
        try {
            return $next($request);
        } catch (QueryException|PDOException $e) {
            if (! $this->isLostConnection($e) || $request->attributes->get('pioneer_db_retried') === true) {
                throw $e;
            }

            $request->attributes->set('pioneer_db_retried', true);
            $connection = (string) config('database.default', 'mysql');

            Log::warning('PioneerPath database connection lost; reconnecting and retrying request once.', [
                'connection' => $connection,
                'method' => $request->method(),
                'path' => $request->path(),
                'error' => $e->getMessage(),
            ]);

            DB::purge($connection);
            DB::reconnect($connection);

            return $next($request);
        }
    }

    private function isLostConnection(\Throwable $e): bool
    {
        $message = strtolower($e->getMessage());

        return str_contains($message, 'server has gone away')
            || str_contains($message, 'lost connection')
            || str_contains($message, 'connection timed out')
            || str_contains($message, 'connection refused')
            || str_contains($message, 'no connection could be made')
            || str_contains($message, 'error while sending query packet');
    }
}
