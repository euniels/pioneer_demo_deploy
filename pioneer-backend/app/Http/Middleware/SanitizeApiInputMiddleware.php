<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

class SanitizeApiInputMiddleware
{
    public function handle(Request $request, Closure $next): Response
    {
        if ($this->isManagedApiRoute($request) && $request->isJson()) {
            $result = $this->sanitizeValue($request->all());
            if (! $result['ok']) {
                return response()->json([
                    'success' => false,
                    'message' => 'One or more text fields exceeds the allowed length.',
                ], 422);
            }

            $request->replace(is_array($result['value']) ? $result['value'] : []);
        }

        return $next($request);
    }

    private function sanitizeValue(mixed $value, string $key = ''): mixed
    {
        if (is_array($value)) {
            $sanitized = [];
            foreach ($value as $childKey => $childValue) {
                $result = $this->sanitizeValue($childValue, (string) $childKey);
                if (! $result['ok']) {
                    return $result;
                }
                $sanitized[$childKey] = $result['value'];
            }

            return ['ok' => true, 'value' => $sanitized];
        }

        if (! is_string($value)) {
            return ['ok' => true, 'value' => $value];
        }

        $trimmed = trim($value);

        return strlen($trimmed) <= $this->maxLengthForKey($key)
            ? ['ok' => true, 'value' => $trimmed]
            : ['ok' => false, 'value' => null];
    }

    private function maxLengthForKey(string $key): int
    {
        $normalized = strtolower($key);
        if (str_contains($normalized, 'dataurl') || str_contains($normalized, 'signature')) {
            return 14_000_000;
        }

        if (str_contains($normalized, 'notes')
            || str_contains($normalized, 'description')
            || str_contains($normalized, 'instruction')
            || str_contains($normalized, 'reason')
            || str_contains($normalized, 'remarks')) {
            return 10_000;
        }

        return 2_000;
    }

    private function isManagedApiRoute(Request $request): bool
    {
        $path = trim($request->path(), '/');

        return str_starts_with($path, 'api/fleet')
            || str_starts_with($path, 'api/billing')
            || str_starts_with($path, 'api/vehicles');
    }
}
