<?php

namespace App\Services;

use Carbon\CarbonInterface;
use Illuminate\Http\Client\PendingRequest;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

class GeotabService
{
    private const TIMING_MARKER = 'GEOTAB_TIMING';

    private const ENTITY_TYPE_MISMATCH_FRAGMENT = 'not supported for this operation';

    private const MAX_RETRY_ATTEMPTS = 2;

    private const CONNECT_TIMEOUT_SECONDS = 5;

    private const READ_TIMEOUT_SECONDS = 10;

    private const CIRCUIT_FAILURE_THRESHOLD = 3;

    private const CIRCUIT_WINDOW_SECONDS = 300;

    private const CIRCUIT_COOLDOWN_SECONDS = 300;

    private string $baseUrl;

    private string $database;

    private string $username;

    private string $password;

    private string $server;

    private ?string $requestId = null;

    private ?string $requestEndpoint = null;

    private ?float $requestStartedAt = null;

    private bool $callInProgress = false;

    private bool $circuitFailureRecorded = false;

    public function __construct()
    {
        $this->database = (string) config('geotab.database', '');
        $this->username = (string) config('geotab.username', '');
        $this->password = (string) config('geotab.password', '');
        $this->server = (string) config('geotab.server', 'my.geotab.com');
        $this->baseUrl = "https://{$this->server}/apiv1";
    }

    public function isConfigured(): bool
    {
        return filled($this->database)
            && filled($this->username)
            && filled($this->password);
    }

    public function setTimingContext(?string $requestId, ?string $endpoint, ?float $requestStartedAt): void
    {
        $this->requestId = $requestId;
        $this->requestEndpoint = $endpoint;
        $this->requestStartedAt = $requestStartedAt;
    }

    public function diagnostics(): array
    {
        $state = $this->circuitState();
        $openedUntil = $this->parseCircuitTime($state['openedUntil'] ?? null);

        return [
            'configured' => $this->isConfigured(),
            'credentials' => [
                'database' => filled($this->database),
                'username' => filled($this->username),
                'password' => filled($this->password),
                'server' => filled($this->server),
            ],
            'server' => $this->server,
            'endpoint' => 'https://'.$this->server.'/apiv1',
            'sessionCached' => Cache::has($this->sessionCacheKey()),
            'timeouts' => [
                'connectSeconds' => self::CONNECT_TIMEOUT_SECONDS,
                'readSeconds' => self::READ_TIMEOUT_SECONDS,
                'maxRetryAttemptsInConsole' => self::MAX_RETRY_ATTEMPTS,
            ],
            'circuit' => [
                'open' => $openedUntil !== null && $openedUntil->isFuture(),
                'openedUntil' => $openedUntil?->toIso8601String(),
                'failureCount' => (int) ($state['count'] ?? 0),
                'firstFailureAt' => $state['firstFailureAt'] ?? null,
                'lastFailureAt' => $state['lastFailureAt'] ?? null,
                'lastMethod' => $state['lastMethod'] ?? null,
                'lastError' => $state['lastError'] ?? null,
            ],
        ];
    }

    public function authenticate(): string
    {
        $started = hrtime(true);
        if (! $this->callInProgress) {
            $this->circuitFailureRecorded = false;
        }

        if (! $this->isConfigured()) {
            $this->timingLog('authenticate.failure', [
                'sessionCacheHit' => false,
                'remoteAuthenticateCalled' => false,
                'elapsedMs' => $this->elapsedMs($started),
                'errorType' => \RuntimeException::class,
                'errorMessage' => 'Geotab credentials are not configured.',
            ]);
            throw new \RuntimeException('Geotab credentials are not configured.');
        }

        $sessionCacheHit = Cache::has($this->sessionCacheKey());
        if ($sessionCacheHit) {
            $sessionId = (string) Cache::get($this->sessionCacheKey());
            $this->timingLog('authenticate.finish', [
                'sessionCacheHit' => true,
                'remoteAuthenticateCalled' => false,
                'elapsedMs' => $this->elapsedMs($started),
            ]);

            return $sessionId;
        }

        $this->guardCircuit('Authenticate');

        try {
            $response = $this->httpClient()
                ->post($this->baseUrl, [
                    'method' => 'Authenticate',
                    'params' => [
                        'database' => $this->database,
                        'userName' => $this->username,
                        'password' => $this->password,
                    ],
                ]);

            if (! $response->successful()) {
                throw new \RuntimeException('Unable to authenticate with Geotab.');
            }

            $data = $response->json();

            if (isset($data['error'])) {
                throw new \RuntimeException('Geotab auth failed: '.($data['error']['message'] ?? 'Unknown error'));
            }

            $sessionId = (string) data_get($data, 'result.credentials.sessionId', '');
            $server = (string) data_get($data, 'result.path', $this->server);

            if ($sessionId === '') {
                throw new \RuntimeException('Geotab auth failed: missing session ID.');
            }

            $serverChanged = $server !== '' && $server !== 'ThisServer' && $server !== $this->server;
            if ($server !== '' && $server !== 'ThisServer') {
                $this->server = $server;
                $this->baseUrl = "https://{$server}/apiv1";
            }

            Cache::put($this->sessionCacheKey(), $sessionId, now()->addHours(22));
            Cache::put($this->serverCacheKey(), $this->server, now()->addHours(22));

            $this->timingLog('authenticate.finish', [
                'sessionCacheHit' => false,
                'remoteAuthenticateCalled' => true,
                'elapsedMs' => $this->elapsedMs($started),
                'returnedServer' => $this->server,
                'serverChanged' => $serverChanged,
            ]);

            $this->recordCircuitSuccess();

            return $sessionId;
        } catch (\Throwable $e) {
            $this->timingLog('authenticate.failure', [
                'sessionCacheHit' => false,
                'remoteAuthenticateCalled' => true,
                'elapsedMs' => $this->elapsedMs($started),
                'errorType' => get_class($e),
                'errorMessage' => $e->getMessage(),
            ]);

            $this->recordCircuitFailure('Authenticate', $e);

            throw $e;
        }
    }

    public function call(string $method, array $params = []): mixed
    {
        $started = hrtime(true);
        $retriedAfterInvalidSession = ($params['__retried'] ?? false) === true;
        $retryAttempt = (int) ($params['__retry_attempt'] ?? 0);
        $previousCallInProgress = $this->callInProgress;
        $this->callInProgress = true;
        if (! $previousCallInProgress) {
            $this->circuitFailureRecorded = false;
        }

        try {
            $this->guardCircuit($method);

            $sessionId = $this->authenticate();
            $server = (string) Cache::get($this->serverCacheKey(), $this->server);
            $url = "https://{$server}/apiv1";

            $requestParams = $params;
            unset($requestParams['__retried'], $requestParams['__retry_attempt']);
            $requestParams['credentials'] = [
                'database' => $this->database,
                'userName' => $this->username,
                'sessionId' => $sessionId,
            ];

            $response = $this->httpClient()
                ->post($url, [
                    'method' => $method,
                    'params' => $requestParams,
                ]);

            if (! $response->successful()) {
                if ($this->isRetryableHttpStatus($response->status()) && $retryAttempt < $this->maxRetryAttempts()) {
                    $this->timingLog('api_call.retry', [
                        'geotabMethod' => $method,
                        'elapsedMs' => $this->elapsedMs($started),
                        'classification' => 'http_'.$response->status(),
                        'httpStatus' => $response->status(),
                        'retryAttempt' => $retryAttempt + 1,
                    ]);

                    $retry = $params;
                    $retry['__retry_attempt'] = $retryAttempt + 1;
                    $this->backoff($retryAttempt);

                    return $this->call($method, $retry);
                }

                $this->timingLog('api_call.failure', [
                    'geotabMethod' => $method,
                    'elapsedMs' => $this->elapsedMs($started),
                    'result' => 'http_failure',
                    'httpStatus' => $response->status(),
                    'retriedAfterInvalidSession' => $retriedAfterInvalidSession,
                    'errorType' => \RuntimeException::class,
                    'errorMessage' => 'Geotab request failed with HTTP '.$response->status().'.',
                ]);

                throw new \RuntimeException('Geotab request failed with HTTP '.$response->status().'.');
            }

            $data = $response->json();

            if (isset($data['error'])) {
                $message = (string) ($data['error']['message'] ?? 'Unknown error');
                if (
                    str_contains($message, 'Incorrect Login Credentials')
                    || str_contains($message, 'InvalidUserException')
                    || str_contains($message, 'DbUnavailableException')
                ) {
                    Cache::forget($this->sessionCacheKey());
                    Cache::forget($this->serverCacheKey());

                    $this->timingLog('api_call.invalid_session_retry', [
                        'geotabMethod' => $method,
                        'elapsedMs' => $this->elapsedMs($started),
                        'geotabErrorMessage' => $message,
                        'retriedAfterInvalidSession' => $retriedAfterInvalidSession,
                    ]);

                    $retry = $params;
                    unset($retry['credentials']);

                    if (($retry['__retried'] ?? false) !== true) {
                        $retry['__retried'] = true;

                        return $this->call($method, $retry);
                    }
                }

                if ($this->isEntityTypeMismatchMessage($message)) {
                    $this->timingLog('api_call.failure', [
                        'geotabMethod' => $method,
                        'elapsedMs' => $this->elapsedMs($started),
                        'result' => 'geotab_entity_type_mismatch',
                        'retriedAfterInvalidSession' => $retriedAfterInvalidSession,
                        'errorType' => GeotabEntityTypeMismatchException::class,
                        'errorMessage' => $message,
                    ]);

                    throw new GeotabEntityTypeMismatchException('Geotab error: '.$message);
                }

                if ($this->isRetryableGeotabMessage($message) && $retryAttempt < $this->maxRetryAttempts()) {
                    $this->timingLog('api_call.retry', [
                        'geotabMethod' => $method,
                        'elapsedMs' => $this->elapsedMs($started),
                        'classification' => $this->retryClassification($message),
                        'geotabErrorMessage' => $message,
                        'retryAttempt' => $retryAttempt + 1,
                    ]);

                    $retry = $params;
                    $retry['__retry_attempt'] = $retryAttempt + 1;
                    $this->backoff($retryAttempt);

                    return $this->call($method, $retry);
                }

                $this->timingLog('api_call.failure', [
                    'geotabMethod' => $method,
                    'elapsedMs' => $this->elapsedMs($started),
                    'result' => 'geotab_error',
                    'retriedAfterInvalidSession' => $retriedAfterInvalidSession,
                    'errorType' => \RuntimeException::class,
                    'errorMessage' => $message,
                ]);

                throw new \RuntimeException('Geotab error: '.$message);
            }

            $this->timingLog('api_call.finish', [
                'geotabMethod' => $method,
                'elapsedMs' => $this->elapsedMs($started),
                'result' => 'success',
                'retriedAfterInvalidSession' => $retriedAfterInvalidSession,
            ]);

            $this->recordCircuitSuccess();

            return $data['result'] ?? [];
        } catch (\Throwable $e) {
            if ($this->isCircuitOpenException($e)) {
                throw $e;
            }

            if ($this->isRetryableThrowable($e) && $retryAttempt < $this->maxRetryAttempts()) {
                $this->timingLog('api_call.retry', [
                    'geotabMethod' => $method,
                    'elapsedMs' => $this->elapsedMs($started),
                    'classification' => $this->retryClassification($e->getMessage()),
                    'retryAttempt' => $retryAttempt + 1,
                    'errorType' => get_class($e),
                    'errorMessage' => $e->getMessage(),
                ]);

                $retry = $params;
                $retry['__retry_attempt'] = $retryAttempt + 1;
                $this->backoff($retryAttempt);

                return $this->call($method, $retry);
            }

            if ($this->isTimeoutThrowable($e)) {
                Log::channel('geotab')->warning(self::TIMING_MARKER.' api_call.timeout', array_filter([
                    'requestId' => $this->requestId,
                    'endpoint' => $this->requestEndpoint,
                    'sinceRequestStartMs' => $this->sinceRequestStartMs(),
                    'geotabMethod' => $method,
                    'elapsedMs' => $this->elapsedMs($started),
                    'errorType' => get_class($e),
                    'errorMessage' => $e->getMessage(),
                ], fn ($value) => $value !== null));
            }

            if (! $this->alreadyLoggedCallFailure($e)) {
                $this->timingLog('api_call.failure', [
                    'geotabMethod' => $method,
                    'elapsedMs' => $this->elapsedMs($started),
                    'result' => 'exception',
                    'retriedAfterInvalidSession' => $retriedAfterInvalidSession,
                    'errorType' => get_class($e),
                    'errorMessage' => $e->getMessage(),
                ]);
            }

            $this->recordCircuitFailure($method, $e);

            throw $e;
        } finally {
            $this->callInProgress = $previousCallInProgress;
        }
    }

    private function sessionCacheKey(): string
    {
        return 'geotab_session_'.$this->credentialFingerprint();
    }

    private function httpClient(): PendingRequest
    {
        return Http::acceptJson()
            ->withoutVerifying()
            ->connectTimeout(self::CONNECT_TIMEOUT_SECONDS)
            ->timeout(self::READ_TIMEOUT_SECONDS);
    }

    private function guardCircuit(string $method): void
    {
        $state = $this->circuitState();
        $openedUntil = $this->parseCircuitTime($state['openedUntil'] ?? null);

        if ($openedUntil !== null && $openedUntil->isFuture()) {
            throw new \RuntimeException(
                'GeoTab circuit breaker is open until '.$openedUntil->toIso8601String().'; serving cached data only.',
            );
        }

        if ($openedUntil !== null && $openedUntil->isPast()) {
            Cache::forget($this->circuitStateKey());
            Log::channel('geotab')->info('GEOTAB_CIRCUIT half_open', [
                'method' => $method,
                'openedUntil' => $openedUntil->toIso8601String(),
            ]);
        }
    }

    private function recordCircuitSuccess(): void
    {
        Cache::forget($this->circuitStateKey());
    }

    private function recordCircuitFailure(string $method, \Throwable $e): void
    {
        if ($this->circuitFailureRecorded) {
            return;
        }

        $this->circuitFailureRecorded = true;
        $now = now();
        $state = $this->circuitState();
        $firstFailureAt = $this->parseCircuitTime($state['firstFailureAt'] ?? null);
        $withinWindow = $firstFailureAt !== null
            && $firstFailureAt->greaterThanOrEqualTo($now->copy()->subSeconds(self::CIRCUIT_WINDOW_SECONDS));

        $count = $withinWindow ? ((int) ($state['count'] ?? 0)) + 1 : 1;
        $nextState = [
            'count' => $count,
            'firstFailureAt' => ($withinWindow ? $firstFailureAt : $now)->toIso8601String(),
            'lastFailureAt' => $now->toIso8601String(),
            'lastMethod' => $method,
            'lastError' => $e->getMessage(),
        ];

        if ($count >= self::CIRCUIT_FAILURE_THRESHOLD) {
            $openedUntil = $now->copy()->addSeconds(self::CIRCUIT_COOLDOWN_SECONDS);
            $nextState['openedUntil'] = $openedUntil->toIso8601String();

            Log::channel('geotab')->warning('GEOTAB_CIRCUIT opened', [
                'method' => $method,
                'failureCount' => $count,
                'windowSeconds' => self::CIRCUIT_WINDOW_SECONDS,
                'cooldownSeconds' => self::CIRCUIT_COOLDOWN_SECONDS,
                'openedUntil' => $openedUntil->toIso8601String(),
                'errorType' => get_class($e),
                'errorMessage' => $e->getMessage(),
            ]);
        }

        Cache::put($this->circuitStateKey(), $nextState, $now->copy()->addMinutes(15));
    }

    /**
     * @return array<string, mixed>
     */
    private function circuitState(): array
    {
        $state = Cache::get($this->circuitStateKey(), []);

        return is_array($state) ? $state : [];
    }

    private function parseCircuitTime(mixed $value): ?\Illuminate\Support\Carbon
    {
        if (! is_string($value) || trim($value) === '') {
            return null;
        }

        try {
            return \Illuminate\Support\Carbon::parse($value);
        } catch (\Throwable) {
            return null;
        }
    }

    private function circuitStateKey(): string
    {
        return 'geotab_circuit_state_'.$this->credentialFingerprint();
    }

    private function maxRetryAttempts(): int
    {
        return app()->runningInConsole() ? self::MAX_RETRY_ATTEMPTS : 0;
    }

    private function serverCacheKey(): string
    {
        return 'geotab_server_'.$this->credentialFingerprint();
    }

    private function credentialFingerprint(): string
    {
        return md5(strtolower($this->database.'|'.$this->username.'|'.$this->server));
    }

    public function getEntities(
        string $typeName,
        array $search = [],
        ?int $resultsLimit = null,
        array $extraParams = [],
    ): array {
        $params = array_merge(['typeName' => $typeName], $extraParams);

        if ($search !== []) {
            $params['search'] = $search;
        }

        if ($resultsLimit !== null) {
            $params['resultsLimit'] = $resultsLimit;
        }

        $result = $this->call('Get', $params);

        return is_array($result) ? $result : [];
    }

    public function addEntity(string $typeName, array $entity): string
    {
        $result = $this->call('Add', [
            'typeName' => $typeName,
            'entity' => $entity,
        ]);

        return is_scalar($result) ? (string) $result : (string) data_get($result, 'id', '');
    }

    public function setEntity(string $typeName, array $entity): void
    {
        $this->call('Set', [
            'typeName' => $typeName,
            'entity' => $entity,
        ]);
    }

    public function removeEntity(string $typeName, array $entity): void
    {
        $this->call('Remove', [
            'typeName' => $typeName,
            'entity' => $entity,
        ]);
    }

    public function getDevices(): array
    {
        return $this->getEntities('Device', [
            'fromDate' => now()->utc()->toIso8601String(),
        ], 500);
    }

    public function getDeviceStatusInfo(array $diagnostics = []): array
    {
        $extra = [];
        if ($diagnostics !== []) {
            $extra['diagnostics'] = array_values(array_map(
                fn (array $diagnostic): array => ['id' => $diagnostic['id']],
                $diagnostics,
            ));
        }

        return $this->getEntities('DeviceStatusInfo', [], 500, $extra);
    }

    public function getDrivers(): array
    {
        $users = $this->getEntities('User', [], 500);

        return array_values(array_filter($users, function (mixed $user): bool {
            if (! is_array($user)) {
                return false;
            }

            if (data_get($user, 'isDriver') === true) {
                return true;
            }

            foreach (['licenseNumber', 'employeeNo', 'keys', 'companyGroups', 'hosRuleSet'] as $key) {
                $value = data_get($user, $key);
                if ($value !== null && $value !== '' && $value !== []) {
                    return true;
                }
            }

            return true;
        }));
    }

    public function getDriverChanges(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 500): array
    {
        $search = [
            'includeOverlappedChanges' => true,
        ];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('DriverChange', $search, $limit);
    }

    public function getZones(?CarbonInterface $activeAt = null, int $limit = 500): array
    {
        $search = [];

        if ($activeAt !== null) {
            $search['fromDate'] = $this->toUtcString($activeAt);
        }

        return $this->getEntities('Zone', $search, $limit);
    }

    public function getRoutes(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
    {
        $search = [];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('Route', $search, $limit);
    }

    public function getRoutePlanItems(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 500): array
    {
        $search = [];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('RoutePlanItem', $search, $limit);
    }

    public function getTrips(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
    {
        $search = [
            'includeOverlappedTrips' => true,
        ];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('Trip', $search, $limit);
    }

    public function getDutyStatusLogs(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
    {
        $search = [
            'includeBoundaryLogs' => true,
        ];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('DutyStatusLog', $search, $limit);
    }

    public function getFillUps(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 200): array
    {
        $search = [];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('FillUp', $search, $limit);
    }

    public function getFuelAndEnergyUsed(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
    {
        $search = [];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('FuelAndEnergyUsed', $search, $limit);
    }

    public function getFuelTransactions(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 500): array
    {
        $search = [];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('FuelTransaction', $search, $limit);
    }

    public function getChargeEvents(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
    {
        $search = [];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('ChargeEvent', $search, $limit);
    }

    public function getExceptionEvents(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
    {
        $search = [
            'includeExceptionCount' => true,
        ];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('ExceptionEvent', $search, $limit);
    }

    public function getFaultData(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
    {
        $search = [];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('FaultData', $search, $limit);
    }

    public function getDvirLogs(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
    {
        $search = [];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('DVIRLog', $search, $limit);
    }

    public function getShipmentLogs(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
    {
        $search = [];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('ShipmentLog', $search, $limit);
    }

    public function getIoxAddOns(?string $deviceId = null, ?int $type = null, int $limit = 250): array
    {
        $search = [];

        if ($deviceId !== null && trim($deviceId) !== '') {
            $search['deviceSearch'] = ['id' => trim($deviceId)];
        }

        if ($type !== null) {
            $search['type'] = $type;
        }

        return $this->getEntities('IoxAddOn', $search, $limit);
    }

    public function getGpsTrail(
        string $deviceId,
        int $limit = 100,
        ?CarbonInterface $from = null,
        ?CarbonInterface $to = null,
    ): array {
        $search = [
            'deviceSearch' => ['id' => $deviceId],
        ];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        return $this->getEntities('LogRecord', $search, $limit);
    }

    public function getAddresses(array $coordinates, bool $movingAddresses = false, bool $hosAddresses = false): array
    {
        if ($coordinates === []) {
            return [];
        }

        $result = $this->call('GetAddresses', [
            'coordinates' => array_values($coordinates),
            'movingAddresses' => $movingAddresses,
            'hosAddresses' => $hosAddresses,
        ]);

        return is_array($result) ? $result : [];
    }

    public function getFeed(
        string $typeName,
        ?string $fromVersion = null,
        array $search = [],
        ?int $resultsLimit = null,
        ?CarbonInterface $fromDate = null,
        ?array $propertySelector = null,
    ): array {
        $params = ['typeName' => $typeName];

        if ($fromVersion !== null && $fromVersion !== '') {
            $params['fromVersion'] = $fromVersion;
        }

        if ($fromDate !== null && ($fromVersion === null || $fromVersion === '')) {
            $search = [
                ...$search,
                'fromDate' => $this->toUtcString($fromDate),
            ];
        }

        if ($search !== []) {
            $params['search'] = $search;
        }

        if ($resultsLimit !== null) {
            $params['resultsLimit'] = $resultsLimit;
        }

        if ($propertySelector !== null && $propertySelector !== []) {
            $params['propertySelector'] = $propertySelector;
        }

        $result = $this->call('GetFeed', $params);

        return is_array($result) ? $result : [];
    }

    public function getLogRecordFeed(?string $fromVersion = null, ?int $resultsLimit = null, ?CarbonInterface $fromDate = null): array
    {
        return $this->getFeed('LogRecord', $fromVersion, [], $resultsLimit, $fromDate);
    }

    public function getTripFeed(
        ?string $fromVersion = null,
        array $search = [],
        ?int $resultsLimit = null,
        ?CarbonInterface $fromDate = null,
    ): array {
        return $this->getFeed('Trip', $fromVersion, $search, $resultsLimit, $fromDate);
    }

    public function getStatusDataFeed(
        ?string $fromVersion = null,
        array $search = [],
        ?int $resultsLimit = null,
        ?CarbonInterface $fromDate = null,
    ): array {
        return $this->getFeed('StatusData', $fromVersion, $search, $resultsLimit, $fromDate);
    }

    public function getDeviceStatusInfoFeed(
        ?string $fromVersion = null,
        array $search = [],
        ?int $resultsLimit = null,
        ?CarbonInterface $fromDate = null,
    ): array {
        return $this->getFeed('DeviceStatusInfo', $fromVersion, $search, $resultsLimit, $fromDate);
    }

    public function getRouteFeed(?string $fromVersion = null, ?int $resultsLimit = null, ?CarbonInterface $fromDate = null): array
    {
        return $this->getFeed('Route', $fromVersion, [], $resultsLimit, $fromDate);
    }

    public function resolveDiagnostics(array $lookupMap): array
    {
        return Cache::remember(
            'geotab_diagnostics_lookup_'.md5(json_encode($lookupMap)),
            now()->addHours(6),
            function () use ($lookupMap): array {
                $allDiagnostics = $this->allDiagnostics();
                $resolved = [];

                foreach ($lookupMap as $alias => $candidates) {
                    $diagnostic = $this->findDiagnostic((array) $candidates, $allDiagnostics);
                    if ($diagnostic !== null) {
                        $resolved[$alias] = $diagnostic;
                    }
                }

                return $resolved;
            },
        );
    }

    public function getStatusDataForDiagnostic(
        string $deviceId,
        string $diagnosticId,
        ?CarbonInterface $from = null,
        ?CarbonInterface $to = null,
        int $limit = 100,
    ): array {
        $search = [
            'deviceSearch' => ['id' => $deviceId],
            'diagnosticSearch' => ['id' => $diagnosticId],
        ];

        if ($from !== null) {
            $search['fromDate'] = $this->toUtcString($from);
        }

        if ($to !== null) {
            $search['toDate'] = $this->toUtcString($to);
        }

        $rows = $this->getEntities('StatusData', $search, $limit);
        usort($rows, fn (array $a, array $b): int => strcmp(
            (string) data_get($b, 'dateTime', ''),
            (string) data_get($a, 'dateTime', ''),
        ));

        return $rows;
    }

    public function getStatusHistory(
        string $deviceId,
        array $diagnostics,
        ?CarbonInterface $from = null,
        ?CarbonInterface $to = null,
        int $limitPerDiagnostic = 48,
    ): array {
        $history = [];

        foreach ($diagnostics as $alias => $diagnostic) {
            $diagnosticId = (string) ($diagnostic['id'] ?? '');
            if ($diagnosticId === '') {
                continue;
            }

            $history[$alias] = $this->getStatusDataForDiagnostic(
                $deviceId,
                $diagnosticId,
                $from,
                $to,
                $limitPerDiagnostic,
            );
        }

        return $history;
    }

    private function allDiagnostics(): array
    {
        return Cache::remember(
            'geotab_all_diagnostics',
            now()->addHours(6),
            fn (): array => $this->getEntities('Diagnostic', [], 5000),
        );
    }

    private function findDiagnostic(array $candidates, array $diagnostics): ?array
    {
        foreach ($candidates as $candidate) {
            $needle = trim((string) $candidate);
            if ($needle === '') {
                continue;
            }

            if (str_starts_with($needle, 'Diagnostic')) {
                return [
                    'id' => $needle,
                    'name' => $needle,
                    'source' => 'SourceGeotabGoId',
                ];
            }

            $selected = $this->selectDiagnosticMatch($diagnostics, $needle);
            if ($selected !== null) {
                return $selected;
            }

            $wildcardMatches = array_values(array_filter(
                $diagnostics,
                fn (mixed $diagnostic): bool => is_array($diagnostic)
                    && str_contains(
                        strtolower(trim((string) data_get($diagnostic, 'name', ''))),
                        strtolower($needle),
                    ),
            ));
            $selected = $this->selectDiagnosticMatch($wildcardMatches, $needle);
            if ($selected !== null) {
                return $selected;
            }
        }

        return null;
    }

    private function selectDiagnosticMatch(array $matches, string $needle): ?array
    {
        if ($matches === []) {
            return null;
        }

        foreach ($matches as $match) {
            $name = strtolower(trim((string) data_get($match, 'name', '')));
            if ($name === strtolower($needle)) {
                return $match;
            }
        }

        return $matches[0] ?? null;
    }

    private function toUtcString(CarbonInterface $value): string
    {
        return $value->copy()->utc()->toIso8601String();
    }

    private function timingLog(string $event, array $context = []): void
    {
        Log::channel('geotab')->info(self::TIMING_MARKER.' '.$event, array_filter([
            'requestId' => $this->requestId,
            'endpoint' => $this->requestEndpoint,
            'sinceRequestStartMs' => $this->sinceRequestStartMs(),
            ...$context,
        ], fn ($value) => $value !== null));
    }

    private function elapsedMs(int $started): float
    {
        return round((hrtime(true) - $started) / 1000000, 2);
    }

    private function sinceRequestStartMs(): ?float
    {
        if ($this->requestStartedAt === null) {
            return null;
        }

        return round((microtime(true) - $this->requestStartedAt) * 1000, 2);
    }

    private function alreadyLoggedCallFailure(\Throwable $e): bool
    {
        $message = $e->getMessage();

        return str_contains($message, 'Geotab request failed with HTTP ')
            || str_contains($message, 'Geotab error: ');
    }

    private function isEntityTypeMismatchMessage(string $message): bool
    {
        $normalized = strtolower($message);

        return str_contains($normalized, self::ENTITY_TYPE_MISMATCH_FRAGMENT)
            && str_contains($normalized, 'please provide an instance of type');
    }

    private function isRetryableHttpStatus(int $status): bool
    {
        return $status === 429 || ($status >= 500 && $status <= 599);
    }

    private function isRetryableGeotabMessage(string $message): bool
    {
        $normalized = strtolower($message);

        return str_contains($normalized, 'overlimitexception')
            || str_contains($normalized, 'over limit')
            || str_contains($normalized, 'rate limit')
            || str_contains($normalized, 'too many requests')
            || str_contains($normalized, 'timeout')
            || str_contains($normalized, 'timed out')
            || str_contains($normalized, 'temporarily unavailable')
            || str_contains($normalized, 'service unavailable');
    }

    private function isRetryableThrowable(\Throwable $e): bool
    {
        return $this->isRetryableGeotabMessage($e->getMessage());
    }

    private function isTimeoutThrowable(\Throwable $e): bool
    {
        return $this->retryClassification($e->getMessage()) === 'timeout';
    }

    private function isCircuitOpenException(\Throwable $e): bool
    {
        return str_contains($e->getMessage(), 'GeoTab circuit breaker is open');
    }

    private function retryClassification(string $message): string
    {
        $normalized = strtolower($message);

        if (str_contains($normalized, 'overlimit') || str_contains($normalized, 'over limit') || str_contains($normalized, 'rate limit')) {
            return 'geotab_over_limit';
        }

        if (str_contains($normalized, 'timeout') || str_contains($normalized, 'timed out')) {
            return 'timeout';
        }

        if (str_contains($normalized, 'too many requests')) {
            return 'http_429';
        }

        return 'transient';
    }

    private function backoff(int $retryAttempt): void
    {
        $baseMs = max(0, (int) config('geotab.retry_base_ms', 250));
        $sleepMs = $baseMs * (2 ** $retryAttempt);
        if ($sleepMs > 0) {
            usleep($sleepMs * 1000);
        }
    }
}

class GeotabEntityTypeMismatchException extends \RuntimeException {}
