<?php

namespace App\Http\Middleware;

use App\Services\RealtimeFleetEventBroadcaster;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

class ApiRateLimitMiddleware
{
    public function __construct(private readonly RealtimeFleetEventBroadcaster $broadcaster) {}

    public function handle(Request $request, Closure $next): Response
    {
        if (! $this->isManagedApiRoute($request)) {
            return $next($request);
        }

        $path = trim(Str::after($request->path(), 'api/'), '/');
        $userKey = $this->userKey($request);

        if ($path === 'fleet/users/login-check') {
            $limited = $this->hitLimit('login:'.$request->ip(), 10, 60);
            if ($limited !== null) {
                return $limited;
            }
        } elseif ($path === 'client-errors') {
            $limited = $this->hitLimit('client-errors:'.$request->ip(), 30, 60);
            if ($limited !== null) {
                return $limited;
            }
        } elseif ($path === 'fleet/stream') {
            if ($this->broadcaster->activeSseClientCountForUser($userKey) >= 5) {
                return $this->tooManyRequests(30);
            }
        } elseif ($path === 'fleet/geotab/writeback'
            || str_starts_with($path, 'fleet/geotab/writeback/')) {
            $limited = $this->hitLimit('writeback:'.$userKey, 30, 60);
            if ($limited !== null) {
                return $limited;
            }
        } else {
            $limited = $this->hitLimit('fleet:'.$userKey, 120, 60);
            if ($limited !== null) {
                return $limited;
            }
        }

        return $next($request);
    }

    private function hitLimit(string $key, int $maxAttempts, int $seconds): ?Response
    {
        $cacheKey = 'pioneer_rate_limit:'.sha1($key);
        $windowKey = $cacheKey.':reset';
        $attempts = (int) Cache::get($cacheKey, 0);
        $resetAt = (int) Cache::get($windowKey, now()->addSeconds($seconds)->timestamp);

        if ($attempts >= $maxAttempts) {
            return $this->tooManyRequests(max(1, $resetAt - now()->timestamp));
        }

        if ($attempts === 0) {
            Cache::put($windowKey, now()->addSeconds($seconds)->timestamp, now()->addSeconds($seconds));
        }
        Cache::put($cacheKey, $attempts + 1, now()->addSeconds($seconds));

        return null;
    }

    private function tooManyRequests(int $retryAfter): Response
    {
        return response()->json([
            'success' => false,
            'message' => 'Too many requests. Please retry shortly.',
        ], 429)->header('Retry-After', (string) $retryAfter);
    }

    private function isManagedApiRoute(Request $request): bool
    {
        $path = trim($request->path(), '/');

        return str_starts_with($path, 'api/fleet')
            || str_starts_with($path, 'api/billing')
            || str_starts_with($path, 'api/vehicles')
            || $path === 'api/client-errors';
    }

    private function userKey(Request $request): string
    {
        $userId = $request->attributes->get('auth_user_id');
        if (is_string($userId) && trim($userId) !== '') {
            return 'user:'.trim($userId);
        }

        return 'ip:'.$request->ip();
    }
}
