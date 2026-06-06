<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Str;

class CorsMiddleware
{
    private const ALLOWED_HEADERS = 'Content-Type, Authorization, X-Requested-With, If-None-Match, If-Modified-Since';

    public function handle(Request $request, Closure $next): mixed
    {
        if ($request->isMethod('OPTIONS')) {
            return $this->withCorsHeaders(response()->json([], 200), $request);
        }

        $response = $next($request);

        return $this->withCorsHeaders($response, $request);
    }

    private function withCorsHeaders(mixed $response, Request $request): mixed
    {
        $origin = trim((string) $request->headers->get('Origin', ''));
        $allowedOrigin = $this->allowedOrigin($origin);

        if ($allowedOrigin !== null) {
            $response->headers->set('Access-Control-Allow-Origin', $allowedOrigin);
        }
        $response->headers->set('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
        $response->headers->set('Access-Control-Allow-Headers', self::ALLOWED_HEADERS);
        $response->headers->set('Access-Control-Expose-Headers', 'ETag, Last-Modified, Content-Encoding, X-Pioneer-Elapsed-Ms, X-Pioneer-Served-From');
        $response->headers->set('Vary', trim(($response->headers->get('Vary') ?: '').', Origin', ', '));
        $response->headers->set('X-Content-Type-Options', 'nosniff');
        $response->headers->set('X-Frame-Options', 'DENY');
        $response->headers->set('X-XSS-Protection', '1; mode=block');
        $response->headers->set('Referrer-Policy', 'strict-origin-when-cross-origin');

        return $response;
    }

    private function allowedOrigin(string $origin): ?string
    {
        if ($origin === '') {
            return null;
        }

        if (app()->environment(['local', 'testing'])) {
            $host = parse_url($origin, PHP_URL_HOST);
            if (in_array($host, ['localhost', '127.0.0.1'], true)) {
                return $origin;
            }
        }

        foreach ($this->allowedOrigins() as $allowed) {
            if ($origin === $allowed) {
                return $origin;
            }
        }

        return null;
    }

    /**
     * @return array<int, string>
     */
    private function allowedOrigins(): array
    {
        $configured = (string) config('pioneer.cors_allowed_origins', '');
        if (trim($configured) === '' && app()->environment(['local', 'testing'])) {
            $configured = 'http://localhost:60732,http://127.0.0.1:60732,http://localhost:60733,http://127.0.0.1:60733,http://localhost:3000,http://127.0.0.1:3000,http://localhost:8080,http://127.0.0.1:8080';
        }

        return collect(explode(',', $configured))
            ->map(fn (string $origin): string => rtrim(trim($origin), '/'))
            ->filter(fn (string $origin): bool => $origin !== '' && ! Str::contains($origin, '*'))
            ->values()
            ->all();
    }
}
