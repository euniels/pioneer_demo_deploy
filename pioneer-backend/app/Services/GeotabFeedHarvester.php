<?php

namespace App\Services;

use App\Models\GeotabFeedCheckpoint;
use App\Models\GeotabFeedRow;
use App\Models\GeotabRouteStopSnapshot;
use App\Models\GpsLog;
use Carbon\CarbonInterface;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Schema;

class GeotabFeedHarvester
{
    public const SUPPORTED_FEEDS = [
        'LogRecord' => 50,
        'StatusData' => 50,
        'Trip' => 100,
        'Route' => 100,
    ];

    private const SNAPSHOT_FRESH_KEY = 'geotab_fleet_snapshot_v4_fresh';

    private const SNAPSHOT_STALE_KEY = 'geotab_fleet_snapshot_v4_stale';

    private const LIVE_FRESH_KEY = 'geotab_live_snapshot_v2_fresh';

    private const WARMUP_STATUS_KEY = 'geotab_warmup_status_v1';

    public function __construct(
        private readonly GeotabService $geotab,
        private readonly ?RealtimeFleetEventBroadcaster $realtime = null,
    ) {}

    public function seedAll(CarbonInterface $from, array $types = []): array
    {
        $summary = [];
        foreach ($this->normalizeTypes($types) as $typeName => $limit) {
            $summary[$typeName] = $this->sync($typeName, $limit, null, [
                'forceSeed' => true,
                'seedFrom' => $from,
            ]);
        }

        return $summary;
    }

    public function syncAll(array $types = []): array
    {
        $summary = [];
        foreach ($this->normalizeTypes($types) as $typeName => $limit) {
            $summary[$typeName] = $this->sync($typeName, $limit);
        }

        return $summary;
    }

    public function sync(string $typeName, int $resultsLimit, ?callable $resolver = null, array $options = []): array
    {
        $started = hrtime(true);
        $checkpoint = $this->checkpoint($typeName);
        $cursor = $this->cursorFromCheckpoint($typeName, $checkpoint);
        $forceSeed = ($options['forceSeed'] ?? false) === true;
        $seedFrom = $this->seedFrom($checkpoint, $options['seedFrom'] ?? null);
        $shouldSeed = $forceSeed || ! $this->checkpointIsSeeded($checkpoint) || $cursor === null;
        $collected = [];
        $batchCount = 0;
        $lastCursor = $cursor;
        $seededThisRun = false;
        $diagnosticAliases = is_array($options['diagnosticAliases'] ?? null)
            ? $options['diagnosticAliases']
            : [];
        $search = is_array($options['search'] ?? null) ? $options['search'] : [];

        try {
            do {
                $requestSeedFrom = $shouldSeed && $batchCount === 0 ? $seedFrom : null;
                $requestCursor = $requestSeedFrom === null ? $lastCursor : null;
                $requestStarted = hrtime(true);
                $response = $resolver !== null
                    ? $resolver($requestCursor, $requestSeedFrom)
                    : $this->geotab->getFeed($typeName, $requestCursor, $search, $resultsLimit, $requestSeedFrom);

                $rows = is_array($response['data'] ?? null) ? $response['data'] : [];
                $nextCursor = trim((string) ($response['toVersion'] ?? ''));
                if ($nextCursor !== '') {
                    $lastCursor = $nextCursor;
                }

                foreach ($rows as $row) {
                    if (is_array($row)) {
                        $collected[] = $row;
                    }
                }

                $this->persistRows($typeName, $rows, $lastCursor, $diagnosticAliases);
                if ($typeName === 'DeviceStatusInfo' && $rows !== []) {
                    $this->realtime?->publishLiveDeviceStatusRows($rows);
                }
                $batchCount++;
                $seededThisRun = $seededThisRun || $requestSeedFrom !== null;
                $memoryRatio = $this->memoryUsageRatio();

                Log::channel('geotab')->info('GEOTAB_TIMING feed.batch', [
                    'typeName' => $typeName,
                    'cursor' => $requestCursor,
                    'seedFrom' => $requestSeedFrom?->toIso8601String(),
                    'toVersion' => $nextCursor,
                    'resultCount' => count($rows),
                    'elapsedMs' => $this->elapsedMs($requestStarted),
                    'memoryUsageRatio' => $memoryRatio,
                ]);

                $shouldContinue = $nextCursor !== ''
                    && $nextCursor !== (string) $requestCursor
                    && count($rows) >= $resultsLimit
                    && $batchCount < 6;

                if ($shouldContinue && $memoryRatio !== null && $memoryRatio >= 0.70) {
                    Log::channel('geotab')->warning('GEOTAB_TIMING feed.memory_backpressure', [
                        'typeName' => $typeName,
                        'cursor' => $lastCursor,
                        'memoryUsageRatio' => $memoryRatio,
                        'message' => 'Processed current batch and deferred remaining feed rows to the next scheduler run.',
                    ]);
                    $shouldContinue = false;
                }
            } while ($shouldContinue);

            $this->storeSuccess(
                $typeName,
                $lastCursor,
                count($collected),
                [
                    'source' => (string) ($options['source'] ?? 'feed-harvester'),
                    'seededThisRun' => $seededThisRun,
                    'elapsedMs' => $this->elapsedMs($started),
                ],
                $seededThisRun ? $seedFrom : null,
            );

            return [
                'typeName' => $typeName,
                'rows' => $collected,
                'rowCount' => count($collected),
                'cursor' => $lastCursor,
                'seeded' => $seededThisRun,
                'elapsedMs' => $this->elapsedMs($started),
            ];
        } catch (\Throwable $e) {
            $this->storeFailure($typeName, $e, [
                'source' => (string) ($options['source'] ?? 'feed-harvester'),
                'cursor' => $lastCursor,
                'seedFrom' => $shouldSeed ? $seedFrom->toIso8601String() : null,
                'elapsedMs' => $this->elapsedMs($started),
            ]);

            Log::channel('geotab')->warning('GEOTAB_TIMING feed.failure', [
                'typeName' => $typeName,
                'cursor' => $lastCursor,
                'seedFrom' => $shouldSeed ? $seedFrom->toIso8601String() : null,
                'errorType' => get_class($e),
                'errorMessage' => $e->getMessage(),
            ]);

            return [
                'typeName' => $typeName,
                'rows' => $collected,
                'rowCount' => count($collected),
                'cursor' => $lastCursor,
                'seeded' => $seededThisRun,
                'error' => $e->getMessage(),
                'elapsedMs' => $this->elapsedMs($started),
            ];
        }
    }

    public function persistRouteStops(array $routes): int
    {
        if (! $this->tableAvailable('geotab_route_stop_snapshots')) {
            return 0;
        }

        $count = 0;
        $capturedAt = now();
        foreach ($routes as $route) {
            if (! is_array($route)) {
                continue;
            }

            foreach ((array) ($route['stops'] ?? []) as $stop) {
                if (! is_array($stop)) {
                    continue;
                }

                $center = is_array($stop['center'] ?? null) ? $stop['center'] : null;
                $payload = $this->sanitizePayload([
                    'route' => $route,
                    'stop' => $stop,
                ]);
                $hash = hash('sha256', (string) json_encode($payload));

                GeotabRouteStopSnapshot::query()->updateOrCreate(
                    ['payload_hash' => $hash],
                    [
                        'route_geotab_id' => $this->stringOrNull($route['routeId'] ?? null),
                        'device_geotab_id' => $this->stringOrNull($route['deviceId'] ?? null),
                        'route_name' => $this->stringOrNull($route['name'] ?? null),
                        'stop_sequence' => (int) ($stop['sequence'] ?? 0),
                        'zone_geotab_id' => $this->stringOrNull($stop['zoneId'] ?? null),
                        'stop_name' => $this->stringOrNull($stop['name'] ?? null),
                        'latitude' => $center !== null ? (float) ($center['latitude'] ?? 0) : null,
                        'longitude' => $center !== null ? (float) ($center['longitude'] ?? 0) : null,
                        'eta_at' => $this->parseDate($stop['eta'] ?? null),
                        'captured_at' => $capturedAt,
                        'payload' => $payload,
                    ],
                );
                $count++;
            }
        }

        return $count;
    }

    public function prune(int $retentionDays = 30, ?int $gpsRetentionDays = null, ?int $routeStopRetentionDays = null): array
    {
        $feedDays = max(1, $retentionDays);
        $gpsDays = max(30, $gpsRetentionDays ?? $feedDays);
        $routeStopDays = max(1, $routeStopRetentionDays ?? $feedDays);
        $feedCutoff = now()->subDays($feedDays);
        $gpsCutoff = now()->subDays($gpsDays);
        $routeStopCutoff = now()->subDays($routeStopDays);
        $deleted = [
            'geotab_feed_rows' => 0,
            'gps_logs' => 0,
            'geotab_route_stop_snapshots' => 0,
        ];

        if ($this->tableAvailable('geotab_feed_rows')) {
            $deleted['geotab_feed_rows'] = GeotabFeedRow::query()
                ->where('recorded_at', '<', $feedCutoff)
                ->delete();
        }

        if ($this->tableAvailable('gps_logs')) {
            $deleted['gps_logs'] = GpsLog::query()
                ->where('recorded_at', '<', $gpsCutoff)
                ->delete();
        }

        if ($this->tableAvailable('geotab_route_stop_snapshots')) {
            $deleted['geotab_route_stop_snapshots'] = GeotabRouteStopSnapshot::query()
                ->where('captured_at', '<', $routeStopCutoff)
                ->delete();
        }

        return [
            'retentionDays' => $feedDays,
            'gpsRetentionDays' => $gpsDays,
            'routeStopRetentionDays' => $routeStopDays,
            'cutoff' => $feedCutoff->toIso8601String(),
            'gpsCutoff' => $gpsCutoff->toIso8601String(),
            'routeStopCutoff' => $routeStopCutoff->toIso8601String(),
            'deleted' => $deleted,
        ];
    }

    public function health(): array
    {
        $checkpoints = [];
        if ($this->tableAvailable('geotab_feed_checkpoints')) {
            foreach (GeotabFeedCheckpoint::query()->orderBy('type_name')->get() as $checkpoint) {
                $lastSuccess = $checkpoint->last_success_at ?? $checkpoint->synced_at;
                $feedLagSeconds = $lastSuccess !== null ? (int) floor($lastSuccess->diffInSeconds(now())) : null;
                $checkpoints[] = [
                    'typeName' => $checkpoint->type_name,
                    'type_name' => $checkpoint->type_name,
                    'seeded' => $checkpoint->seeded_at !== null,
                    'seededAt' => $checkpoint->seeded_at?->toIso8601String(),
                    'seeded_at' => $checkpoint->seeded_at?->toIso8601String(),
                    'seedFrom' => $checkpoint->seed_from?->toIso8601String(),
                    'seed_from' => $checkpoint->seed_from?->toIso8601String(),
                    'cursor' => $checkpoint->cursor,
                    'lastSuccessAt' => $lastSuccess?->toIso8601String(),
                    'last_success' => $lastSuccess?->toIso8601String(),
                    'feedLagSeconds' => $feedLagSeconds,
                    'feed_lag_seconds' => $feedLagSeconds,
                    'lagAgeSeconds' => $feedLagSeconds,
                    'lastRowCount' => (int) ($checkpoint->last_row_count ?? 0),
                    'row_count' => (int) ($checkpoint->last_row_count ?? 0),
                    'consecutiveFailures' => (int) ($checkpoint->consecutive_failures ?? 0),
                    'consecutive_failures' => (int) ($checkpoint->consecutive_failures ?? 0),
                    'lastErrorAt' => $checkpoint->last_error_at?->toIso8601String(),
                    'last_error_at' => $checkpoint->last_error_at?->toIso8601String(),
                    'lastError' => $checkpoint->last_error,
                    'last_error' => $checkpoint->last_error,
                ];
            }
        }

        $lastRuns = [
            'geotab:feed-sync' => Cache::get('geotab_scheduler_last_run_geotab_feed_sync'),
            'geotab:snapshot-warm' => Cache::get('geotab_scheduler_last_run_geotab_snapshot_warm'),
            'geotab:warm-session' => Cache::get('geotab_scheduler_last_run_geotab_warm_session'),
            'geotab:feed-prune' => Cache::get('geotab_scheduler_last_run_geotab_feed_prune'),
            'geotab:writeback-process --limit=10' => Cache::get('geotab_scheduler_last_run_geotab_writeback_process'),
        ];

        $health = [
            'configured' => $this->geotab->isConfigured(),
            'credentials_configured' => $this->geotab->isConfigured(),
            'credentials' => [
                'configured' => $this->geotab->isConfigured(),
                'database' => trim((string) config('geotab.database', '')) !== '',
                'username' => trim((string) config('geotab.username', '')) !== '',
                'password' => trim((string) config('geotab.password', '')) !== '',
                'server' => trim((string) config('geotab.server', '')) !== '',
            ],
            'sessionCached' => Cache::has($this->sessionCacheKey()),
            'session_cached' => Cache::has($this->sessionCacheKey()),
            'session' => [
                'cached' => Cache::has($this->sessionCacheKey()),
                'cacheKey' => 'redacted',
            ],
            'scheduler' => [
                'configuredInApp' => true,
                'productionCron' => '* * * * * php /path/to/artisan schedule:run >> /dev/null 2>&1',
                'firstDeploy' => [
                    'php artisan migrate',
                    'php artisan geotab:feed-seed',
                    'cron: * * * * * php /path/to/artisan schedule:run',
                ],
                'lastRun' => [
                    ...$lastRuns,
                ],
                'commands' => [
                    'geotab:feed-sync' => 'every two minutes, without overlapping for five minutes',
                    'geotab:snapshot-warm' => 'every minute, without overlapping for five minutes',
                    'geotab:warm-session' => 'every ten minutes, session only',
                    'geotab:writeback-process --limit=10' => 'every minute, approved write-back queue only',
                    'geotab:feed-prune' => 'daily at 02:00 using configured retention windows',
                ],
            ],
            'feeds' => $checkpoints,
            'rowCounts' => [
                'geotabFeedRows' => $this->tableAvailable('geotab_feed_rows') ? GeotabFeedRow::query()->count() : null,
                'gpsLogs' => $this->tableAvailable('gps_logs') ? GpsLog::query()->count() : null,
                'routeStopSnapshots' => $this->tableAvailable('geotab_route_stop_snapshots') ? GeotabRouteStopSnapshot::query()->count() : null,
            ],
        ];

        $health['emptyDataDiagnosis'] = $this->emptyDataDiagnosis($health, $lastRuns);

        return $health;
    }

    private function emptyDataDiagnosis(array $health, array $lastRuns): array
    {
        $geotab = $this->geotab->diagnostics();
        $snapshot = $this->snapshotDiagnostics();
        $scheduler = $this->schedulerRunDiagnostics($lastRuns);
        $feedSeeded = collect($health['feeds'] ?? [])
            ->contains(fn (array $feed): bool => ($feed['seeded_at'] ?? null) !== null || ($feed['last_success_at'] ?? null) !== null);
        $rowCounts = is_array($health['rowCounts'] ?? null) ? $health['rowCounts'] : [];
        $feedRows = (int) ($rowCounts['geotabFeedRows'] ?? 0);
        $timeoutDetected = $this->timeoutDetected($health, Cache::get(self::WARMUP_STATUS_KEY));

        [$status, $primaryReason, $actions] = match (true) {
            ! ($geotab['configured'] ?? false) => [
                'blocked',
                'not_configured',
                ['Set GEOTAB_DATABASE, GEOTAB_USERNAME, GEOTAB_PASSWORD, and GEOTAB_SERVER, then run php artisan geotab:warm-session.'],
            ],
            (bool) data_get($geotab, 'circuit.open', false) => [
                'blocked',
                'circuit_open',
                ['Wait until the circuit breaker opens for retry, then run php artisan geotab:warm-session.', 'If it reopens, verify internet access and GeoTab credentials.'],
            ],
            $timeoutDetected => [
                'blocked',
                'geotab_timeout',
                ['Verify network access to '.(string) ($geotab['endpoint'] ?? 'https://my.geotab.com/apiv1').'.', 'Run php artisan geotab:warm-session after connectivity is stable.'],
            ],
            ! $feedSeeded => [
                'blocked',
                'feed_not_seeded',
                ['Run php artisan geotab:feed-seed.', 'Then run php artisan geotab:feed-sync.'],
            ],
            ! (bool) ($scheduler['requiredFresh'] ?? false) => [
                'warning',
                'scheduler_not_running',
                ['Run php artisan schedule:work locally, or install the production cron: * * * * * php /path/to/artisan schedule:run >> /dev/null 2>&1.'],
            ],
            ! (bool) ($snapshot['hasSnapshot'] ?? false) => [
                'warning',
                'snapshot_not_warmed',
                ['Run php artisan geotab:snapshot-warm.', 'Keep the scheduler running so snapshot caches stay fresh.'],
            ],
            $feedRows === 0 => [
                'warning',
                'database_empty',
                ['Run php artisan geotab:feed-seed, then php artisan geotab:feed-sync.', 'Confirm geotab_feed_rows receives rows.'],
            ],
            ! (bool) ($snapshot['hasOperationalData'] ?? false) => [
                'warning',
                'cache_empty',
                ['Run php artisan geotab:snapshot-warm.', 'If still empty, inspect GeoTab data permissions and feed checkpoint errors.'],
            ],
            default => [
                'ok',
                'ok',
                ['No action required.'],
            ],
        };

        return [
            'status' => $status,
            'primaryReason' => $primaryReason,
            'recommendedActions' => $actions,
            'generatedAt' => now()->toIso8601String(),
            'geotab' => $geotab,
            'snapshot' => $snapshot,
            'scheduler' => $scheduler,
            'feedSeeded' => $feedSeeded,
            'rowCounts' => $rowCounts,
            'warmupStatus' => Cache::get(self::WARMUP_STATUS_KEY),
        ];
    }

    private function snapshotDiagnostics(): array
    {
        $fresh = Cache::get(self::SNAPSHOT_FRESH_KEY);
        $stale = Cache::get(self::SNAPSHOT_STALE_KEY);
        $live = Cache::get(self::LIVE_FRESH_KEY);
        $snapshot = is_array($fresh) ? $fresh : (is_array($stale) ? $stale : []);
        $liveVehicles = is_array(data_get($live, 'vehicles')) ? data_get($live, 'vehicles') : [];

        $counts = [
            'vehicles' => $this->countList(data_get($snapshot, 'vehicles')),
            'drivers' => $this->countList(data_get($snapshot, 'drivers')),
            'trips' => $this->countList(data_get($snapshot, 'trips')),
            'routes' => $this->countList(data_get($snapshot, 'routes')),
            'liveVehicles' => $this->countList($liveVehicles),
        ];

        return [
            'freshCached' => is_array($fresh),
            'staleCached' => is_array($stale),
            'liveCached' => is_array($live),
            'hasSnapshot' => is_array($fresh) || is_array($stale),
            'hasOperationalData' => collect($counts)->sum() > 0,
            'counts' => $counts,
        ];
    }

    private function schedulerRunDiagnostics(array $lastRuns): array
    {
        $required = [
            'geotab:feed-sync' => 600,
            'geotab:snapshot-warm' => 300,
            'geotab:warm-session' => 1200,
        ];
        $ages = [];
        $fresh = [];

        foreach ($lastRuns as $command => $timestamp) {
            $age = $this->ageSeconds($timestamp);
            $ages[$command] = $age;
            if (isset($required[$command])) {
                $fresh[$command] = $age !== null && $age <= $required[$command];
            }
        }

        return [
            'lastRuns' => $lastRuns,
            'ageSeconds' => $ages,
            'requiredFresh' => collect($fresh)->every(fn (bool $ok): bool => $ok),
            'freshRequiredCommands' => $fresh,
        ];
    }

    private function timeoutDetected(array $health, mixed $warmupStatus): bool
    {
        $errors = collect($health['feeds'] ?? [])
            ->pluck('last_error')
            ->filter()
            ->push(is_array($warmupStatus) ? ($warmupStatus['message'] ?? $warmupStatus['error'] ?? null) : null)
            ->filter()
            ->map(fn (mixed $value): string => strtolower((string) $value));

        return $errors->contains(fn (string $value): bool => str_contains($value, 'timeout')
            || str_contains($value, 'timed out')
            || str_contains($value, 'curl error 28'));
    }

    private function ageSeconds(mixed $timestamp): ?int
    {
        if (! is_string($timestamp) || trim($timestamp) === '') {
            return null;
        }

        try {
            return (int) Carbon::parse($timestamp)->diffInSeconds(now());
        } catch (\Throwable) {
            return null;
        }
    }

    private function countList(mixed $value): int
    {
        return is_array($value) ? count($value) : 0;
    }

    private function persistRows(string $typeName, array $rows, ?string $cursor, array $diagnosticAliases): int
    {
        if (! $this->tableAvailable('geotab_feed_rows')) {
            return 0;
        }

        $count = 0;
        foreach ($rows as $row) {
            if (! is_array($row)) {
                continue;
            }

            $payload = $this->sanitizePayload($row);
            $recordedAt = $this->recordedAt($typeName, $row);
            $deviceId = $this->idFromValue(data_get($row, 'device'));
            $diagnosticId = $this->idFromValue(data_get($row, 'diagnostic'));
            $diagnosticAlias = $diagnosticId !== '' ? ($diagnosticAliases[$diagnosticId] ?? null) : null;
            if ($diagnosticAlias !== null) {
                $payload['diagnosticAlias'] = $diagnosticAlias;
            }

            $tripId = $this->tripIdForRow($typeName, $row);
            $hash = hash('sha256', $typeName.'|'.(string) json_encode($payload));

            GeotabFeedRow::query()->updateOrCreate(
                ['payload_hash' => $hash],
                [
                    'type_name' => $typeName,
                    'geotab_id' => $this->stringOrNull($this->idFromValue($row)),
                    'device_geotab_id' => $this->stringOrNull($deviceId),
                    'trip_id' => $this->stringOrNull($tripId),
                    'diagnostic_geotab_id' => $this->stringOrNull($diagnosticId),
                    'diagnostic_alias' => $this->stringOrNull($diagnosticAlias),
                    'feed_cursor' => $this->stringOrNull($cursor),
                    'recorded_at' => $recordedAt,
                    'payload' => $payload,
                ],
            );

            if ($typeName === 'LogRecord') {
                $this->persistGpsLogRow($row, null, $deviceId);
            }

            if ($typeName === 'Trip') {
                $this->associateGpsLogsWithTrip($row, $tripId);
            }

            $count++;
        }

        return $count;
    }

    private function persistGpsLogRow(array $row, ?string $tripId, ?string $deviceId = null): void
    {
        if (! $this->tableAvailable('gps_logs')) {
            return;
        }

        $resolvedDeviceId = trim((string) ($deviceId ?: $this->idFromValue(data_get($row, 'device'))));
        $latitude = data_get($row, 'latitude');
        $longitude = data_get($row, 'longitude');
        $recordedAt = $this->parseDate(data_get($row, 'dateTime'));
        if ($resolvedDeviceId === '' || ! is_numeric($latitude) || ! is_numeric($longitude) || $recordedAt === null) {
            return;
        }

        $geotabLogId = $this->idFromValue($row);
        if ($geotabLogId === '') {
            $geotabLogId = sha1($resolvedDeviceId.'|'.$recordedAt->toIso8601String().'|'.$latitude.'|'.$longitude);
        }

        GpsLog::query()->updateOrCreate(
            ['geotab_log_id' => $geotabLogId],
            [
                'trip_id' => $tripId,
                'device_geotab_id' => $resolvedDeviceId,
                'latitude' => (float) $latitude,
                'longitude' => (float) $longitude,
                'speed' => (float) data_get($row, 'speed', 0),
                'bearing' => null,
                'recorded_at' => $recordedAt,
                'meta' => [
                    'source' => 'geotab_feed_harvester',
                    'rawId' => $this->idFromValue($row),
                ],
                ...$this->gpsLogAssociationFields($tripId),
            ],
        );
    }

    private function associateGpsLogsWithTrip(array $row, string $tripId): void
    {
        if ($tripId === '' || ! $this->tableAvailable('gps_logs')) {
            return;
        }

        $deviceId = $this->idFromValue(data_get($row, 'device'));
        $start = $this->parseDate(data_get($row, 'start'));
        $stop = $this->parseDate(data_get($row, 'stop') ?: data_get($row, 'nextTripStart')) ?? now();
        if ($deviceId === '' || $start === null) {
            return;
        }

        GpsLog::query()
            ->where('device_geotab_id', $deviceId)
            ->whereBetween('recorded_at', [$start->copy()->subMinutes(3), $stop->copy()->addMinutes(3)])
            ->where(function ($query): void {
                $query->whereNull('trip_id')
                    ->orWhere('trip_id', '')
                    ->orWhere('trip_id', 'like', 'LIVE-%');
            })
            ->update([
                'trip_id' => $tripId,
                'association_status' => 'matched',
                'association_review_reason' => null,
                'updated_at' => now(),
            ]);
    }

    /**
     * @return array<string, string|null>
     */
    private function gpsLogAssociationFields(?string $tripId): array
    {
        if (! $this->columnAvailable('gps_logs', 'association_status')) {
            return [];
        }

        $matched = trim((string) $tripId) !== '';

        return [
            'association_status' => $matched ? 'matched' : 'pending_trip_match',
            'association_review_reason' => $matched ? null : 'Awaiting matching Trip feed row for this device/time window.',
        ];
    }

    private function storeSuccess(string $typeName, ?string $cursor, int $rowCount, array $meta, ?CarbonInterface $seedFrom): void
    {
        if ($cursor !== null && $cursor !== '') {
            Cache::put('geotab_feed_checkpoint_'.$typeName, $cursor, now()->addDays(30));
        }

        if (! $this->tableAvailable('geotab_feed_checkpoints')) {
            return;
        }

        $values = [
            'cursor' => $cursor,
            'last_success_at' => now(),
            'last_error_at' => null,
            'last_error' => null,
            'last_row_count' => $rowCount,
            'consecutive_failures' => 0,
            'meta' => $meta,
            'synced_at' => now(),
        ];

        if ($seedFrom !== null) {
            $values['seeded_at'] = now();
            $values['seed_from'] = $seedFrom;
        }

        GeotabFeedCheckpoint::query()->updateOrCreate(
            ['type_name' => $typeName],
            $this->checkpointValues($values),
        );
    }

    private function storeFailure(string $typeName, \Throwable $e, array $meta): void
    {
        if (! $this->tableAvailable('geotab_feed_checkpoints')) {
            return;
        }

        $checkpoint = $this->checkpoint($typeName);
        GeotabFeedCheckpoint::query()->updateOrCreate(
            ['type_name' => $typeName],
            $this->checkpointValues([
                'cursor' => $checkpoint?->cursor,
                'last_error_at' => now(),
                'last_error' => $e->getMessage(),
                'consecutive_failures' => ((int) ($checkpoint?->consecutive_failures ?? 0)) + 1,
                'meta' => $meta,
            ]),
        );
    }

    private function checkpoint(string $typeName): ?GeotabFeedCheckpoint
    {
        if (! $this->tableAvailable('geotab_feed_checkpoints')) {
            return null;
        }

        return GeotabFeedCheckpoint::query()->where('type_name', $typeName)->first();
    }

    private function cursorFromCheckpoint(string $typeName, ?GeotabFeedCheckpoint $checkpoint): ?string
    {
        $cursor = trim((string) ($checkpoint?->cursor ?? ''));
        if ($cursor !== '') {
            return $cursor;
        }

        $cached = trim((string) Cache::get('geotab_feed_checkpoint_'.$typeName, ''));

        return $cached !== '' ? $cached : null;
    }

    private function checkpointIsSeeded(?GeotabFeedCheckpoint $checkpoint): bool
    {
        return $checkpoint !== null && $checkpoint->seeded_at !== null;
    }

    private function seedFrom(?GeotabFeedCheckpoint $checkpoint, mixed $seedFrom): CarbonInterface
    {
        if ($seedFrom instanceof CarbonInterface) {
            return $seedFrom;
        }

        if (is_string($seedFrom) && trim($seedFrom) !== '') {
            return Carbon::parse($seedFrom);
        }

        if ($checkpoint?->seed_from !== null) {
            return $checkpoint->seed_from;
        }

        $days = (int) config('geotab.feed_default_seed_days', 30);

        return now()->subDays(max(1, $days));
    }

    private function normalizeTypes(array $types): array
    {
        if ($types === []) {
            return self::SUPPORTED_FEEDS;
        }

        $normalized = [];
        foreach ($types as $key => $value) {
            $typeName = is_string($key) ? $key : (string) $value;
            if (isset(self::SUPPORTED_FEEDS[$typeName])) {
                $normalized[$typeName] = self::SUPPORTED_FEEDS[$typeName];
            }
        }

        return $normalized;
    }

    private function recordedAt(string $typeName, array $row): ?Carbon
    {
        return match ($typeName) {
            'Trip', 'Route' => $this->parseDate(data_get($row, 'start') ?: data_get($row, 'startTime') ?: data_get($row, 'dateTime')),
            default => $this->parseDate(data_get($row, 'dateTime')),
        };
    }

    private function tripIdForRow(string $typeName, array $row): string
    {
        if ($typeName !== 'Trip') {
            return '';
        }

        $id = $this->idFromValue($row);

        return $id !== '' ? $this->displayTripId($id) : '';
    }

    private function displayTripId(string $rawId): string
    {
        $clean = strtoupper(preg_replace('/[^A-Z0-9]/i', '', $rawId) ?: '');

        return $clean !== '' ? 'TRP-'.substr($clean, -6) : '';
    }

    private function sanitizePayload(mixed $value): mixed
    {
        if (is_array($value)) {
            $sanitized = [];
            foreach ($value as $key => $item) {
                $sanitized[$key] = $this->sanitizePayload($item);
            }

            return $sanitized;
        }

        if (is_string($value)) {
            $decoded = html_entity_decode($value, ENT_QUOTES | ENT_HTML5, 'UTF-8');
            $converted = mb_convert_encoding($decoded, 'UTF-8', 'UTF-8');

            return trim($converted);
        }

        return $value;
    }

    private function parseDate(mixed $value): ?Carbon
    {
        if ($value instanceof CarbonInterface) {
            return Carbon::parse($value->toIso8601String());
        }

        if ($value === null || $value === '') {
            return null;
        }

        try {
            return Carbon::parse($value);
        } catch (\Throwable) {
            return null;
        }
    }

    private function idFromValue(mixed $value): string
    {
        if (is_array($value)) {
            return (string) ($value['id'] ?? '');
        }

        return is_scalar($value) ? (string) $value : '';
    }

    private function stringOrNull(mixed $value): ?string
    {
        $string = trim((string) $value);

        return $string !== '' ? $string : null;
    }

    private function tableAvailable(string $table): bool
    {
        try {
            return Schema::hasTable($table);
        } catch (\Throwable) {
            return false;
        }
    }

    private function columnAvailable(string $table, string $column): bool
    {
        try {
            return Schema::hasColumn($table, $column);
        } catch (\Throwable) {
            return false;
        }
    }

    private function checkpointValues(array $values): array
    {
        $filtered = [];
        foreach ($values as $column => $value) {
            if ($this->columnAvailable('geotab_feed_checkpoints', (string) $column)) {
                $filtered[$column] = $value;
            }
        }

        return $filtered;
    }

    private function sessionCacheKey(): string
    {
        return 'geotab_session_'.md5(strtolower(
            (string) config('geotab.database', '')
            .'|'
            .(string) config('geotab.username', '')
            .'|'
            .(string) config('geotab.server', 'my.geotab.com'),
        ));
    }

    private function elapsedMs(int $started): float
    {
        return round((hrtime(true) - $started) / 1000000, 2);
    }

    private function memoryUsageRatio(): ?float
    {
        $limit = $this->memoryLimitBytes();
        if ($limit === null || $limit <= 0) {
            return null;
        }

        return round(memory_get_usage(true) / $limit, 4);
    }

    private function memoryLimitBytes(): ?int
    {
        $value = trim((string) ini_get('memory_limit'));
        if ($value === '' || $value === '-1') {
            return null;
        }

        $unit = strtolower(substr($value, -1));
        $number = (int) $value;

        return match ($unit) {
            'g' => $number * 1024 * 1024 * 1024,
            'm' => $number * 1024 * 1024,
            'k' => $number * 1024,
            default => $number,
        };
    }
}
