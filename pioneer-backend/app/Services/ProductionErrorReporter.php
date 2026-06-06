<?php

namespace App\Services;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use Throwable;

class ProductionErrorReporter
{
    private const SECRET_KEY_PARTS = [
        'password',
        'token',
        'authorization',
        'api_key',
        'apikey',
        'secret',
        'vapid',
        'geotab',
        'firebase',
        'credential',
        'private_key',
    ];

    private const PERSONAL_DATA_KEY_PARTS = [
        'name',
        'email',
        'phone',
        'contact',
        'license',
        'address',
        'driver',
        'client',
        'customer',
        'recipient',
        'signature',
        'gps',
        'latitude',
        'longitude',
    ];

    public function report(Throwable $exception, ?Request $request = null, array $context = []): void
    {
        $request ??= request();

        Log::channel('app_errors')->error('pioneerpath.unhandled_exception', [
            'exception' => [
                'class' => get_class($exception),
                'message' => Str::limit($exception->getMessage(), 2000, ''),
                'file' => $exception->getFile(),
                'line' => $exception->getLine(),
                'trace' => $exception->getTraceAsString(),
            ],
            'request' => $this->requestContext($request),
            'userId' => $request->attributes->get('auth_user_id'),
            'role' => $request->attributes->get('auth_role'),
            ...$this->sanitize($context),
        ]);
    }

    /**
     * @return array<string, mixed>
     */
    public function requestContext(Request $request): array
    {
        return [
            'method' => $request->method(),
            'url' => $request->fullUrl(),
            'path' => $request->path(),
            'ip' => $request->ip(),
            'userAgent' => Str::limit((string) $request->userAgent(), 500, ''),
            'headers' => $this->sanitize($request->headers->all()),
            'body' => $this->sanitize($request->all()),
        ];
    }

    public function sanitize(mixed $value): mixed
    {
        if (is_array($value)) {
            $sanitized = [];
            foreach ($value as $key => $item) {
                $keyString = strtolower((string) $key);
                $sanitized[$key] = $this->isSensitiveKey($keyString)
                    ? '[redacted]'
                    : ($this->isPersonalDataKey($keyString)
                        ? '[personal-data-masked]'
                        : $this->sanitize($item));
            }

            return $sanitized;
        }

        if (is_string($value)) {
            return Str::limit($value, 2000, '');
        }

        return $value;
    }

    private function isSensitiveKey(string $key): bool
    {
        foreach (self::SECRET_KEY_PARTS as $part) {
            if (str_contains($key, $part)) {
                return true;
            }
        }

        return false;
    }

    private function isPersonalDataKey(string $key): bool
    {
        foreach (self::PERSONAL_DATA_KEY_PARTS as $part) {
            if (str_contains($key, $part)) {
                return true;
            }
        }

        return false;
    }
}
