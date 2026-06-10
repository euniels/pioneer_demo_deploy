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
        $category = $this->categoryFor($request, $path);

        if ($category === 'sse') {
            $maxClients = max(1, (int) config('pioneer.rate_limits.sse_clients_per_user', 5));
            if ($this->broadcaster->activeSseClientCountForUser($userKey) >= $maxClients) {
                return $this->tooManyRequests(30, 'live', 'Too many live stream connections are open for this account.');
            }

            return $next($request);
        }

        $config = $this->limitConfig($category);
        $key = $this->limitKey($category, $request, $userKey);
        $limited = $this->hitLimit($key, $config['maxAttempts'], $config['windowSeconds'], $category);
        if ($limited !== null) {
            return $limited;
        }

        return $next($request);
    }

    private function hitLimit(string $key, int $maxAttempts, int $seconds, string $category): ?Response
    {
        $cacheKey = 'pioneer_rate_limit:'.sha1($key);
        $windowKey = $cacheKey.':reset';
        $attempts = (int) Cache::get($cacheKey, 0);
        $resetAt = (int) Cache::get($windowKey, now()->addSeconds($seconds)->timestamp);

        if ($attempts >= $maxAttempts) {
            return $this->tooManyRequests(max(1, $resetAt - now()->timestamp), $category);
        }

        if ($attempts === 0) {
            Cache::put($windowKey, now()->addSeconds($seconds)->timestamp, now()->addSeconds($seconds));
        }
        Cache::put($cacheKey, $attempts + 1, now()->addSeconds($seconds));

        return null;
    }

    private function tooManyRequests(int $retryAfter, string $category, string $message = 'Too many requests. Please retry shortly.'): Response
    {
        $this->recordTooManyRequests($category);

        return response()->json([
            'success' => false,
            'message' => $message,
            'category' => $category,
            'retryAfter' => $retryAfter,
        ], 429)->header('Retry-After', (string) $retryAfter);
    }

    private function categoryFor(Request $request, string $path): string
    {
        if ($path === 'fleet/users/login-check') {
            return 'login';
        }

        if ($path === 'client-errors') {
            return 'client_errors';
        }

        if ($path === 'fleet/stream') {
            return 'sse';
        }

        if ($path === 'fleet/geotab/writeback'
            || str_starts_with($path, 'fleet/geotab/writeback/')) {
            return 'writeback';
        }

        if ($this->isLiveReadPath($path)) {
            return 'live';
        }

        return $request->isMethod('GET') ? 'reads' : 'mutations';
    }

    private function isLiveReadPath(string $path): bool
    {
        return in_array($path, [
            'fleet/live',
            'fleet/summary/live',
            'vehicles/locations',
        ], true)
            || $path === 'fleet/telemetry/assets'
            || str_starts_with($path, 'fleet/telemetry/assets/');
    }

    /**
     * @return array{maxAttempts: int, windowSeconds: int}
     */
    private function limitConfig(string $category): array
    {
        $config = (array) config('pioneer.rate_limits.'.$category, []);

        return [
            'maxAttempts' => max(1, (int) ($config['max_attempts'] ?? 120)),
            'windowSeconds' => max(1, (int) ($config['window_seconds'] ?? 60)),
        ];
    }

    private function limitKey(string $category, Request $request, string $userKey): string
    {
        if (in_array($category, ['login', 'client_errors'], true)) {
            return $category.':'.$request->ip();
        }

        return $category.':'.$userKey;
    }

    private function recordTooManyRequests(string $category): void
    {
        $today = now()->toDateString();
        $categoryKey = 'pioneer_rate_limit_429:'.$today.':'.$category;
        $totalKey = 'pioneer_rate_limit_429:'.$today.':total';
        $ttl = now()->addDays(2);

        Cache::increment($categoryKey);
        Cache::put($categoryKey.':last_at', now()->toIso8601String(), $ttl);
        Cache::put($categoryKey.':label', $category, $ttl);
        Cache::put($categoryKey, (int) Cache::get($categoryKey, 0), $ttl);

        Cache::increment($totalKey);
        Cache::put($totalKey, (int) Cache::get($totalKey, 0), $ttl);
        Cache::put('pioneer_rate_limit_429:last_category', $category, $ttl);
        Cache::put('pioneer_rate_limit_429:last_at', now()->toIso8601String(), $ttl);
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
