<?php

namespace App\Http\Middleware;

use App\Services\JwtAuthService;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

class FleetCrudPermissionMiddleware
{
    private const WRITE_METHODS = ['POST', 'PUT', 'PATCH', 'DELETE'];

    public function __construct(private readonly JwtAuthService $jwtAuth) {}

    public function handle(Request $request, Closure $next): Response
    {
        if (! $this->isManagedApiRoute($request)) {
            return $next($request);
        }

        $method = strtoupper($request->method());
        $path = trim(Str::after($request->path(), 'api/'), '/');

        if ($this->isPublicRoute($path, $method)) {
            return $next($request);
        }

        $role = $this->authenticatedRole($request);
        if ($role === null) {
            return $this->errorResponse('A valid sign-in token is required for this fleet action.', 401);
        }

        $authUser = $request->attributes->get('auth_user');
        if (($authUser?->must_change_password ?? false)
            && ! in_array($path, ['fleet/auth/change-password', 'fleet/auth/logout'], true)) {
            return $this->errorResponse('Password change is required before continuing.', 423);
        }

        if (! $this->isAllowed($request, $role)) {
            return $this->errorResponse('Your role is not allowed to perform this fleet action.', 403);
        }

        return $next($request);
    }

    private function errorResponse(string $message, int $code): Response
    {
        return response()->json([
            'status' => 'error',
            'message' => $message,
            'code' => $code,
        ], $code);
    }

    private function isManagedApiRoute(Request $request): bool
    {
        $path = trim($request->path(), '/');

        return str_starts_with($path, 'api/fleet')
            || str_starts_with($path, 'api/billing')
            || str_starts_with($path, 'api/vehicles');
    }

    private function authenticatedRole(Request $request): ?string
    {
        $token = $request->bearerToken();
        if (($token === null || trim($token) === '') && $request->query('token')) {
            $token = (string) $request->query('token');
        }

        if ($token !== null && trim($token) !== '') {
            $payload = $this->jwtAuth->verifyAccessToken($token);
            if ($payload === null) {
                return null;
            }

            $role = $this->normalizeRole((string) ($payload['role'] ?? ''));
            $request->attributes->set('auth_payload', $payload);
            $request->attributes->set('auth_user', $payload['user'] ?? null);
            $request->attributes->set('auth_user_id', (string) ($payload['sub'] ?? ''));
            $request->attributes->set('auth_role', $role);

            return $role;
        }

        if (app()->runningUnitTests()) {
            return $this->normalizeRole(
                (string) ($request->headers->get('X-Pioneer-Role')
                    ?: $request->headers->get('X-User-Role')
                    ?: $request->input('actorRole')
                    ?: $request->input('currentUserRole')
                    ?: 'super_administrator')
            );
        }

        return null;
    }

    private function normalizeRole(string $role): string
    {
        $normalized = Str::of($role)
            ->lower()
            ->replace(['-', '.', ' '], '_')
            ->afterLast('userrole_')
            ->toString();

        return match ($normalized) {
            'admin', 'administrator', 'superadmin' => 'super_administrator',
            'systemadmin' => 'system_administrator',
            'manager' => 'fleet_manager',
            'finance' => 'accounting_staff',
            default => $normalized,
        };
    }

    private function isAllowed(Request $request, string $role): bool
    {
        if ($role === 'super_administrator') {
            return true;
        }

        $method = strtoupper($request->method());
        $write = in_array($method, self::WRITE_METHODS, true);
        $path = trim(Str::after($request->path(), 'api/'), '/');

        if (str_starts_with($path, 'fleet/auth/')) {
            return true;
        }

        return match ($role) {
            'system_administrator' => $this->systemAdministratorAllowed($path, $method, $write),
            'fleet_manager' => $this->fleetManagerAllowed($path, $method, $write),
            'dispatcher' => $this->dispatcherAllowed($path, $method, $write),
            'driver' => $this->driverAllowed($path, $method, $write),
            'accounting_staff' => $this->accountingAllowed($path, $method, $write),
            default => false,
        };
    }

    private function isPublicRoute(string $path, string $method): bool
    {
        if (in_array($path, [
            'fleet/users/login-check',
            'fleet/auth/refresh',
            'fleet/auth/forgot-password',
            'fleet/auth/reset-password',
        ], true)) {
            return true;
        }

        if ($method !== 'GET') {
            return false;
        }

        return $path === 'fleet/maps/config'
            || $path === 'fleet/push/config';
    }

    private function systemAdministratorAllowed(string $path, string $method, bool $write): bool
    {
        if (str_starts_with($path, 'fleet/settings')) {
            return false;
        }

        if (str_starts_with($path, 'fleet/users')) {
            return true;
        }

        return true;
    }

    private function fleetManagerAllowed(string $path, string $method, bool $write): bool
    {
        if (str_starts_with($path, 'fleet/settings')) {
            return false;
        }

        if (! $write) {
            return true;
        }

        if ($method === 'DELETE') {
            return false;
        }

        return str_starts_with($path, 'fleet/vehicles/manual')
            || str_starts_with($path, 'fleet/maintenance/history')
            || str_starts_with($path, 'fleet/maintenance/work-orders')
            || str_starts_with($path, 'fleet/fuel/events')
            || str_starts_with($path, 'fleet/routes')
            || str_starts_with($path, 'fleet/zones')
            || str_starts_with($path, 'fleet/geotab/routes')
            || str_starts_with($path, 'fleet/geotab/writeback');
    }

    private function dispatcherAllowed(string $path, string $method, bool $write): bool
    {
        if (str_starts_with($path, 'billing') || str_starts_with($path, 'fleet/settings')) {
            return false;
        }

        if (! $write) {
            return str_starts_with($path, 'fleet/trips')
                || str_starts_with($path, 'fleet/live')
                || str_starts_with($path, 'fleet/summary')
                || str_starts_with($path, 'fleet/dashboard')
                || str_starts_with($path, 'fleet/client-tracking')
                || str_starts_with($path, 'fleet/pod')
                || str_starts_with($path, 'fleet/vehicles')
                || str_starts_with($path, 'vehicles')
                || str_starts_with($path, 'fleet/drivers')
                || str_starts_with($path, 'fleet/routes')
                || str_starts_with($path, 'fleet/clients')
                || str_starts_with($path, 'fleet/notifications')
                || str_starts_with($path, 'fleet/notification-preferences');
        }

        return str_starts_with($path, 'fleet/trips')
            || str_starts_with($path, 'fleet/pod');
    }

    private function driverAllowed(string $path, string $method, bool $write): bool
    {
        if (! $write) {
            return str_starts_with($path, 'fleet/trips')
                || str_starts_with($path, 'fleet/client-tracking')
                || str_starts_with($path, 'fleet/pod')
                || str_starts_with($path, 'fleet/notifications')
                || str_starts_with($path, 'fleet/notification-preferences');
        }

        return str_starts_with($path, 'fleet/trips')
            || str_starts_with($path, 'fleet/pod')
            || str_starts_with($path, 'fleet/notifications')
            || str_starts_with($path, 'fleet/notification-preferences');
    }

    private function accountingAllowed(string $path, string $method, bool $write): bool
    {
        if (str_starts_with($path, 'fleet/users')
            || str_starts_with($path, 'fleet/settings')
            || str_starts_with($path, 'fleet/dispatch')
            || str_starts_with($path, 'fleet/geotab/writeback')) {
            return false;
        }

        if (! $write) {
            return str_starts_with($path, 'billing')
                || str_starts_with($path, 'fleet/trips')
                || str_starts_with($path, 'fleet/clients')
                || str_starts_with($path, 'fleet/vehicles')
                || str_starts_with($path, 'vehicles')
                || str_starts_with($path, 'fleet/pod')
                || str_starts_with($path, 'fleet/reports/vehicle-subscription-coverage')
                || str_starts_with($path, 'fleet/notifications')
                || str_starts_with($path, 'fleet/notification-preferences');
        }

        return str_starts_with($path, 'billing/invoices');
    }
}
