<?php

use App\Http\Controllers\Api\GeotabController;
use App\Jobs\QueueHealthProbeJob;
use App\Models\FleetClient;
use App\Models\GeotabFeedCheckpoint;
use App\Models\GeotabWriteJob;
use App\Models\NotificationHistory;
use App\Models\SystemSetting;
use App\Services\GeotabFeedHarvester;
use App\Services\GeotabService;
use App\Services\GeotabWriteBackService;
use App\Services\PioneerBackupHealthService;
use App\Services\PioneerIntegrityCheckService;
use App\Services\PushSenderService;
use Database\Seeders\PioneerDemoFlowSeeder;
use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

Artisan::command('pioneer:demo-seed {--force : Allow seeding demo data in production}', function () {
    if (app()->environment('production') && ! (bool) $this->option('force')) {
        $this->error('Refusing to seed demo data in production without --force.');

        return 1;
    }

    $this->call('db:seed', [
        '--class' => PioneerDemoFlowSeeder::class,
        '--force' => (bool) $this->option('force'),
    ]);

    Cache::forget('geotab_fleet_snapshot_v4_fresh');
    Cache::forget('geotab_fleet_snapshot_v4_stale');
    Cache::forget('geotab_live_snapshot_v2_fresh');
    Cache::forget('geotab_live_snapshot_v2_stale');

    $this->info('Demo data seeded. Login with admin@pioneerpath.local or demo role accounts using Pioneer@12345.');

    return 0;
})->purpose('Seed realistic demo data for client walkthroughs.');

Artisan::command('geotab:warm-session', function () {
    /** @var GeotabService $geotab */
    $geotab = app(GeotabService::class);
    $statusKey = 'geotab_warmup_status_v1';
    $runKey = 'geotab_scheduler_last_run_geotab_warm_session';

    Cache::put($statusKey, [
        'state' => 'warming',
        'startedAt' => now()->toIso8601String(),
        'completedAt' => null,
        'error' => null,
    ], now()->addHours(6));

    try {
        $geotab->authenticate();
        $status = Cache::get($statusKey, []);
        $startedAt = is_array($status) ? ($status['startedAt'] ?? now()->toIso8601String()) : now()->toIso8601String();

        Cache::put($statusKey, [
            'state' => 'ready',
            'startedAt' => $startedAt,
            'completedAt' => now()->toIso8601String(),
            'error' => null,
        ], now()->addHours(6));
        Cache::put($runKey, now()->toIso8601String(), now()->addDays(2));

        $this->info('Geotab session warmed successfully.');
    } catch (Throwable $e) {
        $status = Cache::get($statusKey, []);
        Cache::put($statusKey, [
            'state' => 'failed',
            'startedAt' => is_array($status) ? ($status['startedAt'] ?? now()->toIso8601String()) : now()->toIso8601String(),
            'completedAt' => now()->toIso8601String(),
            'error' => $e->getMessage(),
        ], now()->addHours(6));

        report($e);
        $this->error('Geotab warmup failed: '.$e->getMessage());

        return 1;
    }

    return 0;
})->purpose('Warm the GeoTab session without harvesting feeds.');

Artisan::command('geotab:feed-seed {--from= : UTC date such as 2026-04-01. Defaults to 30 days ago.} {--types= : Optional comma-separated feed types, e.g. LogRecord,Trip}', function () {
    $from = trim((string) $this->option('from'));
    if ($from === '') {
        $from = now()->subDays(30)->toDateString();
        $this->info('No --from date supplied; seeding from '.$from.' using the 30-day production default.');
    }

    /** @var GeotabFeedHarvester $harvester */
    $harvester = app(GeotabFeedHarvester::class);
    $types = array_filter(array_map(
        fn (string $type): string => trim($type),
        explode(',', (string) $this->option('types'))
    ));
    $summary = $harvester->seedAll(Carbon::parse($from)->startOfDay(), $types);

    foreach ($summary as $typeName => $result) {
        $this->line(sprintf(
            '%s: %d rows, cursor=%s%s',
            $typeName,
            (int) ($result['rowCount'] ?? 0),
            (string) ($result['cursor'] ?? ''),
            isset($result['error']) ? ' error='.$result['error'] : '',
        ));
    }

    return 0;
})->purpose('Seed supported Geotab feeds once with fromDate and store feed cursors.');

Artisan::command('geotab:feed-sync {--types= : Optional comma-separated feed types, e.g. LogRecord,Trip}', function () {
    Cache::put('geotab_scheduler_last_run_geotab_feed_sync', now()->toIso8601String(), now()->addDays(2));

    /** @var GeotabFeedHarvester $harvester */
    $harvester = app(GeotabFeedHarvester::class);
    $types = array_filter(array_map(
        fn (string $type): string => trim($type),
        explode(',', (string) $this->option('types'))
    ));
    $summary = $harvester->syncAll($types);

    foreach ($summary as $typeName => $result) {
        $this->line(sprintf(
            '%s: %d rows, cursor=%s%s',
            $typeName,
            (int) ($result['rowCount'] ?? 0),
            (string) ($result['cursor'] ?? ''),
            isset($result['error']) ? ' error='.$result['error'] : '',
        ));
    }

    return 0;
})->purpose('Sync supported Geotab feeds from stored fromVersion cursors.');

Artisan::command('geotab:snapshot-warm', function () {
    /** @var GeotabController $controller */
    $controller = app(GeotabController::class);

    try {
        $summary = $controller->warmSnapshotCachesForConsole();
        Cache::put('geotab_scheduler_last_run_geotab_snapshot_warm', now()->toIso8601String(), now()->addDays(2));

        $this->info(sprintf(
            'Snapshot warmed: %d vehicles, %d trips, %d routes, %d live vehicles.',
            (int) ($summary['vehicles'] ?? 0),
            (int) ($summary['trips'] ?? 0),
            (int) ($summary['routes'] ?? 0),
            (int) ($summary['liveVehicles'] ?? 0),
        ));

        return 0;
    } catch (Throwable $e) {
        report($e);
        $this->error('Snapshot warm failed: '.$e->getMessage());

        return 1;
    }
})->purpose('Build fast local fleet snapshot caches for user-facing pages.');

Artisan::command('geotab:feed-prune {--days= : Raw GeoTab feed retention override} {--gps-days= : GPS log retention override}', function () {
    Cache::put('geotab_scheduler_last_run_geotab_feed_prune', now()->toIso8601String(), now()->addDays(2));

    $settings = Schema::hasTable('system_settings') ? SystemSetting::query()->first() : null;
    $feedDays = $this->option('days') !== null && trim((string) $this->option('days')) !== ''
        ? (int) $this->option('days')
        : (int) ($settings?->raw_geotab_feed_retention_days ?? 30);
    $gpsDays = $this->option('gps-days') !== null && trim((string) $this->option('gps-days')) !== ''
        ? (int) $this->option('gps-days')
        : (int) ($settings?->gps_log_retention_days ?? 90);
    $notificationDays = (int) ($settings?->notification_history_retention_days ?? 90);
    $auditDays = max(365, (int) ($settings?->audit_log_retention_days ?? 365));

    /** @var GeotabFeedHarvester $harvester */
    $harvester = app(GeotabFeedHarvester::class);
    $result = $harvester->prune($feedDays, $gpsDays, $feedDays);

    foreach ($result['deleted'] as $table => $count) {
        $this->line(sprintf('%s: deleted %d rows', $table, (int) $count));
    }
    if (Schema::hasTable('notification_histories')) {
        $deletedNotifications = NotificationHistory::query()
            ->where('created_at', '<', now()->subDays(max(30, $notificationDays)))
            ->delete();
        $this->line(sprintf('notification_histories: deleted %d rows', (int) $deletedNotifications));
    }

    $auditCutoff = now()->subDays($auditDays);
    $deletedAuditEntries = 0;
    $pruneAuditTrail = function (array $trail) use ($auditCutoff, &$deletedAuditEntries): array {
        return array_values(array_filter($trail, function (mixed $entry) use ($auditCutoff, &$deletedAuditEntries): bool {
            if (! is_array($entry)) {
                return true;
            }

            $timestamp = $entry['timestamp'] ?? $entry['at'] ?? null;
            if (! is_string($timestamp) || trim($timestamp) === '') {
                return true;
            }

            try {
                $keep = Carbon::parse($timestamp)->greaterThanOrEqualTo($auditCutoff);
            } catch (Throwable) {
                return true;
            }

            if (! $keep) {
                $deletedAuditEntries++;
            }

            return $keep;
        }));
    };

    if (Schema::hasTable('system_settings') && Schema::hasColumn('system_settings', 'audit_log')) {
        SystemSetting::query()->each(function (SystemSetting $setting) use ($pruneAuditTrail): void {
            $trail = is_array($setting->audit_log) ? $setting->audit_log : [];
            $setting->forceFill(['audit_log' => $pruneAuditTrail($trail)])->saveQuietly();
        });
    }
    if (Schema::hasTable('fleet_clients') && Schema::hasColumn('fleet_clients', 'audit_trail')) {
        FleetClient::query()->each(function (FleetClient $client) use ($pruneAuditTrail): void {
            $trail = is_array($client->audit_trail) ? $client->audit_trail : [];
            $client->forceFill(['audit_trail' => $pruneAuditTrail($trail)])->saveQuietly();
        });
    }
    if (Schema::hasTable('geotab_write_jobs') && Schema::hasColumn('geotab_write_jobs', 'audit_trail')) {
        GeotabWriteJob::query()->each(function (GeotabWriteJob $job) use ($pruneAuditTrail): void {
            $trail = is_array($job->audit_trail) ? $job->audit_trail : [];
            $job->forceFill(['audit_trail' => $pruneAuditTrail($trail)])->saveQuietly();
        });
    }
    $this->line(sprintf('audit_trails: pruned %d entries older than %d days', $deletedAuditEntries, $auditDays));

    $this->line(sprintf(
        'retention feed=%dd gps=%dd notifications=%dd audit=%dd',
        max(1, $feedDays),
        max(30, $gpsDays),
        max(30, $notificationDays),
        $auditDays,
    ));

    return 0;
})->purpose('Prune raw Geotab operational feed rows outside the retention window.');

Artisan::command('geotab:writeback-process {--limit=10 : Maximum approved jobs to process}', function () {
    Cache::put('geotab_scheduler_last_run_geotab_writeback_process', now()->toIso8601String(), now()->addDays(2));

    /** @var GeotabWriteBackService $writeBack */
    $writeBack = app(GeotabWriteBackService::class);
    $summary = $writeBack->processApproved(max(1, (int) $this->option('limit')));

    $this->line(sprintf(
        'processed=%d succeeded=%d failed=%d skipped=%d',
        (int) ($summary['processed'] ?? 0),
        (int) ($summary['succeeded'] ?? 0),
        (int) ($summary['failed'] ?? 0),
        (int) ($summary['skipped'] ?? 0),
    ));

    return 0;
})->purpose('Process approved GeoTab write-back jobs with retry-safe auditing.');

Artisan::command('notifications:test {--title=PioneerPath Test Notification}', function () {
    if (! Schema::hasTable('notification_histories')) {
        $this->error('notification_histories table is not available.');

        return 1;
    }

    $notification = NotificationHistory::query()->create([
        'notification_id' => 'test-'.Str::lower(Str::random(18)),
        'title' => (string) $this->option('title'),
        'message' => 'This verifies the persisted notification and browser push pipeline.',
        'category' => 'system',
        'status' => 'sent',
        'audience' => 'internal',
        'payload' => [
            'url' => '/notifications',
            'icon' => '/icons/Icon-192.png',
            'tag' => 'pioneerpath-test',
        ],
        'delivered_at' => now(),
    ]);

    $summary = app(PushSenderService::class)->send($notification);
    $this->line('Notification inserted: '.$notification->notification_id);
    $this->line('Push status: '.$summary['status']);

    return 0;
})->purpose('Insert a test notification and exercise browser push delivery.');

Artisan::command('geotab:ops-summary', function () {
    $seedFrom = now()->subDays(30)->toDateString();

    $this->line('PioneerPath GeoTab production rollout commands:');
    $this->line('1. php artisan migrate');
    $this->line('2. php artisan geotab:feed-seed');
    $this->line('   # default seed date today-30d: '.$seedFrom);
    $this->line('3. Add production scheduler cron: * * * * * php /path/to/artisan schedule:run >> /dev/null 2>&1');
    $this->line('4. Verify: php artisan geotab:feed-sync && php artisan route:list --path=fleet');
    $this->line('5. Configure VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, and VAPID_SUBJECT for browser push.');

    return 0;
})->purpose('Print GeoTab feed and scheduler rollout commands.');

Artisan::command('geotab:diagnose', function () {
    /** @var GeotabFeedHarvester $harvester */
    $harvester = app(GeotabFeedHarvester::class);
    $health = $harvester->health();
    $diagnosis = is_array($health['emptyDataDiagnosis'] ?? null) ? $health['emptyDataDiagnosis'] : [];
    $snapshot = is_array($diagnosis['snapshot'] ?? null) ? $diagnosis['snapshot'] : [];
    $scheduler = is_array($diagnosis['scheduler'] ?? null) ? $diagnosis['scheduler'] : [];

    $status = (string) ($diagnosis['status'] ?? 'unknown');
    $reason = (string) ($diagnosis['primaryReason'] ?? 'unknown');

    $this->line('PioneerPath GeoTab diagnosis');
    $this->line('Status: '.$status);
    $this->line('Primary reason: '.$reason);

    $counts = is_array($snapshot['counts'] ?? null) ? $snapshot['counts'] : [];
    $this->line(sprintf(
        'Snapshot counts: vehicles=%d drivers=%d trips=%d routes=%d liveVehicles=%d',
        (int) ($counts['vehicles'] ?? 0),
        (int) ($counts['drivers'] ?? 0),
        (int) ($counts['trips'] ?? 0),
        (int) ($counts['routes'] ?? 0),
        (int) ($counts['liveVehicles'] ?? 0),
    ));

    $rowCounts = is_array($diagnosis['rowCounts'] ?? null) ? $diagnosis['rowCounts'] : [];
    $this->line(sprintf(
        'Database rows: geotabFeedRows=%s gpsLogs=%s routeStopSnapshots=%s',
        $rowCounts['geotabFeedRows'] ?? 'n/a',
        $rowCounts['gpsLogs'] ?? 'n/a',
        $rowCounts['routeStopSnapshots'] ?? 'n/a',
    ));

    $this->line('Scheduler required commands fresh: '.(((bool) ($scheduler['requiredFresh'] ?? false)) ? 'yes' : 'no'));
    foreach ((array) ($diagnosis['recommendedActions'] ?? []) as $action) {
        $this->line('- '.$action);
    }

    return $status === 'ok' ? 0 : 1;
})->purpose('Explain why GeoTab-backed fleet data is empty or degraded.');

Artisan::command('pioneer:runtime-check', function () {
    $checks = [];
    $capture = function (string $name, callable $check) use (&$checks): void {
        try {
            [$ok, $message] = $check();
        } catch (Throwable $e) {
            $ok = false;
            $message = $e->getMessage();
        }
        $checks[] = ['name' => $name, 'ok' => (bool) $ok, 'message' => (string) $message];
    };
    $ageSeconds = function (mixed $timestamp): ?int {
        if (! is_string($timestamp) || trim($timestamp) === '') {
            return null;
        }

        try {
            return (int) Carbon::parse($timestamp)->diffInSeconds(now());
        } catch (Throwable) {
            return null;
        }
    };
    $fresh = function (string $key, int $maxAgeSeconds) use ($ageSeconds): bool {
        $age = $ageSeconds(Cache::get($key));

        return $age !== null && $age <= $maxAgeSeconds;
    };

    $capture('Config cache safe GeoTab config', fn (): array => [
        trim((string) config('geotab.server', '')) !== ''
            && array_key_exists('database', config('geotab', []))
            && array_key_exists('http_feed_sync', config('geotab', [])),
        'GeoTab runtime values are available from config/geotab.php.',
    ]);
    $capture('Cache store runtime', function (): array {
        Cache::put('pioneer_runtime_check_cache', 'ok', 30);

        return [
            Cache::get('pioneer_runtime_check_cache') === 'ok',
            'Default cache store read/write completed using '.config('cache.default').'.',
        ];
    });
    $capture('Redis cache configured', function (): array {
        if (config('cache.default') !== 'redis') {
            return [false, 'CACHE_STORE must be redis for production locks and hot fleet snapshots.'];
        }

        Cache::store('redis')->put('pioneer_runtime_check_redis', 'ok', 30);

        return [
            Cache::store('redis')->get('pioneer_runtime_check_redis') === 'ok',
            'Redis cache store read/write completed.',
        ];
    });
    $capture('Queue configured', fn (): array => [
        config('queue.default') === 'redis',
        config('queue.default') === 'redis' ? 'Queue connection is redis.' : 'QUEUE_CONNECTION must be redis.',
    ]);
    $capture('Scheduler feed sync fresh', fn (): array => [
        $fresh('geotab_scheduler_last_run_geotab_feed_sync', 600),
        'geotab:feed-sync should run within the last 10 minutes.',
    ]);
    $capture('Scheduler snapshot warm fresh', fn (): array => [
        $fresh('geotab_scheduler_last_run_geotab_snapshot_warm', 300),
        'geotab:snapshot-warm should run within the last 5 minutes.',
    ]);
    $capture('Scheduler writeback fresh', fn (): array => [
        $fresh('geotab_scheduler_last_run_geotab_writeback_process', 300),
        'geotab:writeback-process should run within the last 5 minutes.',
    ]);
    $capture('GeoTab diagnosis not blocked', function (): array {
        /** @var GeotabFeedHarvester $harvester */
        $harvester = app(GeotabFeedHarvester::class);
        $diagnosis = $harvester->health()['emptyDataDiagnosis'] ?? [];
        $status = (string) ($diagnosis['status'] ?? 'unknown');
        $reason = (string) ($diagnosis['primaryReason'] ?? 'unknown');

        return [
            $status !== 'blocked',
            'GeoTab diagnosis status='.$status.' reason='.$reason.'.',
        ];
    });

    foreach ($checks as $check) {
        $this->line(sprintf(
            '%s %s - %s',
            $check['ok'] ? '[PASS]' : '[FAIL]',
            $check['name'],
            $check['message'],
        ));
    }

    $failed = collect($checks)->where('ok', false)->count();
    if ($failed > 0) {
        $this->error($failed.' runtime check(s) failed.');

        return 1;
    }

    $this->info('PioneerPath runtime check passed.');

    return 0;
})->purpose('Verify cache, Redis, queue, scheduler, and GeoTab runtime readiness.');

Artisan::command('pioneer:queue-check {--wait=5 : Seconds to wait for an async worker to process the probe} {--json : Output the check result as JSON}', function () {
    $connection = (string) config('queue.default');
    $probeId = (string) Str::uuid();
    $probeKey = 'pioneer_queue_probe_'.$probeId;
    $waitSeconds = max(0, min(30, (int) $this->option('wait')));
    $startedAt = microtime(true);
    $dispatched = false;
    $processedAt = null;
    $error = null;

    try {
        QueueHealthProbeJob::dispatch($probeId);
        $dispatched = true;
    } catch (Throwable $e) {
        $error = $e->getMessage();
    }

    if ($dispatched) {
        $deadline = time() + $waitSeconds;
        do {
            $processedAt = Cache::get($probeKey);
            if (is_string($processedAt) && trim($processedAt) !== '') {
                break;
            }

            if ($waitSeconds === 0) {
                break;
            }

            usleep(250000);
        } while (time() <= $deadline);
    }

    $lastProcessed = Cache::get('pioneer_queue_last_processed_at');
    $lastProcessedAt = is_string($lastProcessed) && trim($lastProcessed) !== '' ? Carbon::parse($lastProcessed) : null;
    $workerFresh = $lastProcessedAt !== null && $lastProcessedAt->greaterThan(now()->subMinutes(10));
    $processed = is_string($processedAt) && trim($processedAt) !== '';
    $ok = $dispatched && ($processed || $connection === 'sync' || $workerFresh);
    $payload = [
        'ok' => $ok,
        'connection' => $connection,
        'probeId' => $probeId,
        'probeQueued' => $dispatched,
        'probeProcessed' => $processed,
        'workerFresh' => $workerFresh,
        'lastProcessedAt' => $lastProcessedAt?->toIso8601String(),
        'lastProcessedAgeSeconds' => $lastProcessedAt?->diffInSeconds(now()),
        'elapsedMs' => round((microtime(true) - $startedAt) * 1000, 2),
        'error' => $error,
        'recommendedProductionWorker' => 'php artisan queue:work redis --queue=default --sleep=3 --tries=3 --max-time=3600',
    ];

    if ($this->option('json')) {
        $this->line(json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));

        return $ok ? 0 : 1;
    }

    $this->line('queue_connection='.$connection);
    $this->line('probe_queued='.($dispatched ? 'yes' : 'no'));
    $this->line('probe_processed='.($processed ? 'yes' : 'no'));
    $this->line('worker_fresh='.($workerFresh ? 'yes' : 'no'));
    $this->line('last_processed_at='.($payload['lastProcessedAt'] ?? 'none'));
    $this->line('recommended_worker='.$payload['recommendedProductionWorker']);

    if (! $ok) {
        $this->error($error !== null ? 'Queue probe failed: '.$error : 'Queue worker has not processed a probe recently.');

        return 1;
    }

    $this->info('Queue probe processed successfully.');

    return 0;
})->purpose('Verify queue dispatch and worker processing readiness.');

Artisan::command('pioneer:scheduler-status {--json : Output scheduler freshness as JSON}', function () {
    $ageSeconds = function (mixed $timestamp): ?int {
        if (! is_string($timestamp) || trim($timestamp) === '') {
            return null;
        }

        try {
            return (int) Carbon::parse($timestamp)->diffInSeconds(now());
        } catch (Throwable) {
            return null;
        }
    };
    $commands = [
        'geotab:feed-sync' => ['key' => 'geotab_scheduler_last_run_geotab_feed_sync', 'maxAgeSeconds' => 600, 'required' => true],
        'geotab:snapshot-warm' => ['key' => 'geotab_scheduler_last_run_geotab_snapshot_warm', 'maxAgeSeconds' => 300, 'required' => true],
        'geotab:writeback-process --limit=10' => ['key' => 'geotab_scheduler_last_run_geotab_writeback_process', 'maxAgeSeconds' => 300, 'required' => true],
        'geotab:warm-session' => ['key' => 'geotab_scheduler_last_run_geotab_warm_session', 'maxAgeSeconds' => 900, 'required' => false],
        'geotab:feed-prune' => ['key' => 'geotab_scheduler_last_run_geotab_feed_prune', 'maxAgeSeconds' => 172800, 'required' => false],
    ];
    $checks = [];
    foreach ($commands as $command => $config) {
        $lastRun = Cache::get($config['key']);
        $age = $ageSeconds($lastRun);
        $fresh = $age !== null && $age <= (int) $config['maxAgeSeconds'];
        $checks[] = [
            'command' => $command,
            'cacheKey' => $config['key'],
            'required' => (bool) $config['required'],
            'lastRun' => is_string($lastRun) ? $lastRun : null,
            'ageSeconds' => $age,
            'maxAgeSeconds' => (int) $config['maxAgeSeconds'],
            'fresh' => $fresh,
        ];
    }

    $requiredFresh = collect($checks)
        ->filter(fn (array $check): bool => (bool) $check['required'])
        ->every(fn (array $check): bool => (bool) $check['fresh']);
    $payload = [
        'ok' => $requiredFresh,
        'requiredFresh' => $requiredFresh,
        'productionCron' => '* * * * * cd /path/to/pioneer-backend && php artisan schedule:run >> /dev/null 2>&1',
        'checks' => $checks,
    ];

    if ($this->option('json')) {
        $this->line(json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));

        return $requiredFresh ? 0 : 1;
    }

    foreach ($checks as $check) {
        $this->line(sprintf(
            '%s required=%s fresh=%s age_seconds=%s last_run=%s',
            $check['command'],
            $check['required'] ? 'yes' : 'no',
            $check['fresh'] ? 'yes' : 'no',
            $check['ageSeconds'] === null ? 'n/a' : (string) $check['ageSeconds'],
            $check['lastRun'] ?? 'none',
        ));
    }
    $this->line('production_cron='.$payload['productionCron']);

    if (! $requiredFresh) {
        $this->error('Required scheduler commands are stale. Keep Laravel schedule:run active every minute.');

        return 1;
    }

    $this->info('Required scheduler commands are fresh.');

    return 0;
})->purpose('Report scheduler freshness for GeoTab sync, cache warming, and write-back processing.');

Artisan::command('pioneer:performance-check {--json : Output the check result as JSON}', function () {
    $checks = [];
    $record = function (string $name, string $status, string $message, array $context = []) use (&$checks): void {
        $checks[] = [
            'name' => $name,
            'status' => in_array($status, ['pass', 'warn', 'fail'], true) ? $status : 'warn',
            'message' => $message,
            'context' => $context,
        ];
    };
    $countRows = function (string $table): ?int {
        if (! Schema::hasTable($table)) {
            return null;
        }

        try {
            return DB::table($table)->count();
        } catch (Throwable) {
            return null;
        }
    };
    $indexExists = function (string $table, string $index): bool {
        if (! Schema::hasTable($table)
            || ! preg_match('/^[A-Za-z0-9_]+$/', $table)
            || ! preg_match('/^[A-Za-z0-9_]+$/', $index)) {
            return false;
        }

        try {
            $connection = DB::connection();
            $driver = $connection->getDriverName();
            if ($driver === 'mysql' || $driver === 'mariadb') {
                return count($connection->select("SHOW INDEX FROM `{$table}` WHERE Key_name = ?", [$index])) > 0;
            }

            if ($driver === 'sqlite') {
                return collect($connection->select('PRAGMA index_list("'.$table.'")'))
                    ->contains(fn (object $row): bool => (string) ($row->name ?? '') === $index);
            }

            if ($driver === 'pgsql') {
                return count($connection->select(
                    'select indexname from pg_indexes where schemaname = current_schema() and tablename = ? and indexname = ?',
                    [$table, $index],
                )) > 0;
            }

            if ($driver === 'sqlsrv') {
                return count($connection->select(
                    'select i.name from sys.indexes i inner join sys.objects o on i.object_id = o.object_id where o.name = ? and i.name = ?',
                    [$table, $index],
                )) > 0;
            }
        } catch (Throwable) {
            return false;
        }

        return false;
    };

    $freshSnapshot = Cache::get('geotab_fleet_snapshot_v4_fresh');
    $staleSnapshot = Cache::get('geotab_fleet_snapshot_v4_stale');
    $liveSnapshot = Cache::get('geotab_live_snapshot_v2_fresh');
    $record(
        'Live cache readiness',
        is_array($liveSnapshot) && $liveSnapshot !== [] ? 'pass' : 'warn',
        is_array($liveSnapshot) && $liveSnapshot !== []
            ? 'Warm live tracking cache is available for /api/fleet/live.'
            : 'Warm live tracking cache is missing; scheduler should run geotab:snapshot-warm.',
        ['cacheKey' => 'geotab_live_snapshot_v2_fresh'],
    );
    $record(
        'Fleet snapshot readiness',
        is_array($freshSnapshot) || is_array($staleSnapshot) ? 'pass' : 'warn',
        is_array($freshSnapshot)
            ? 'Fresh fleet snapshot is available for summary endpoints.'
            : (is_array($staleSnapshot)
                ? 'Only stale fleet snapshot is available; summary endpoints can degrade gracefully.'
                : 'No fleet snapshot cache is available; summary endpoints will return empty/degraded data.'),
        [
            'freshCacheKey' => 'geotab_fleet_snapshot_v4_fresh',
            'staleCacheKey' => 'geotab_fleet_snapshot_v4_stale',
        ],
    );

    foreach ([
        'gps_logs',
        'geotab_feed_rows',
        'geotab_write_jobs',
        'manual_vehicles',
        'manual_drivers',
        'fleet_trips',
        'geotab_route_stop_snapshots',
    ] as $table) {
        $rows = $countRows($table);
        $record(
            'Table '.$table,
            $rows === null ? 'warn' : 'pass',
            $rows === null ? 'Table is unavailable or unreadable.' : 'Table is readable with '.$rows.' row(s).',
            ['rows' => $rows],
        );
    }

    foreach ([
        ['gps_logs', 'gps_trip_device_recorded_idx', 'GPS trail and trip map lookups'],
        ['geotab_feed_rows', 'feed_type_device_recorded_idx', 'GeoTab feed replay and local snapshot building'],
        ['geotab_write_jobs', 'write_jobs_status_next_idx', 'write-back processor polling'],
        ['manual_vehicles', 'manual_vehicles_status_vehicle_type_index', 'manual vehicle filters'],
        ['fleet_trips', 'fleet_trips_status_index', 'trip list filters'],
        ['geotab_route_stop_snapshots', 'geotab_route_stop_snapshots_device_geotab_id_captured_at_index', 'route stop tracking snapshots'],
    ] as [$table, $index, $purpose]) {
        $present = $indexExists($table, $index);
        $record(
            'Index '.$index,
            $present ? 'pass' : 'warn',
            $present
                ? $purpose.' index is present.'
                : $purpose.' index was not found; confirm migrations ran before production load.',
            ['table' => $table, 'index' => $index],
        );
    }

    $controller = GeotabController::class;
    $controllerSource = is_file(app_path('Http/Controllers/Api/GeotabController.php'))
        ? (string) file_get_contents(app_path('Http/Controllers/Api/GeotabController.php'))
        : '';
    $record(
        'Endpoint timing metadata',
        str_contains($controllerSource, 'X-Pioneer-Elapsed-Ms') && str_contains($controllerSource, 'startEndpointTiming')
            ? 'pass'
            : 'warn',
        $controller.' exposes elapsed-time metadata for API performance checks.',
    );
    $record(
        'Cache-first live contract',
        str_contains($controllerSource, 'geotab_live_snapshot_v2_fresh') && str_contains($controllerSource, 'shouldServeCachedSnapshotOnly')
            ? 'pass'
            : 'fail',
        'Live and summary endpoints should serve local cache during HTTP requests.',
    );

    $summary = [
        'passed' => collect($checks)->where('status', 'pass')->count(),
        'warnings' => collect($checks)->where('status', 'warn')->count(),
        'failed' => collect($checks)->where('status', 'fail')->count(),
    ];
    $payload = ['summary' => $summary, 'checks' => $checks];

    if ($this->option('json')) {
        $this->line(json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));

        return $summary['failed'] > 0 ? 1 : 0;
    }

    foreach ($checks as $check) {
        $label = match ($check['status']) {
            'pass' => '[PASS]',
            'fail' => '[FAIL]',
            default => '[WARN]',
        };
        $this->line(sprintf('%s %s - %s', $label, $check['name'], $check['message']));
    }

    if ($summary['failed'] > 0) {
        $this->error($summary['failed'].' performance readiness check(s) failed.');

        return 1;
    }

    $this->info('PioneerPath performance readiness has '.$summary['warnings'].' warning(s).');

    return 0;
})->purpose('Verify fleet API cache, table, index, and response timing readiness.');

Artisan::command('pioneer:production-gate {--strict : Treat deployment warnings as blockers} {--json : Output the gate result as JSON}', function () {
    $strict = (bool) $this->option('strict');
    $checks = [];
    $configured = function (mixed $value, array $placeholders = []): bool {
        $value = trim((string) $value);
        if ($value === '') {
            return false;
        }

        $lower = Str::lower($value);
        foreach (['your-', 'placeholder', 'example.com', 'localhost', '127.0.0.1', '0.0.0.0'] as $unsafeFragment) {
            if (str_contains($lower, $unsafeFragment)) {
                return false;
            }
        }

        foreach ($placeholders as $placeholder) {
            if ($lower === Str::lower((string) $placeholder)) {
                return false;
            }
        }

        return true;
    };
    $record = function (string $name, string $status, string $message, array $context = []) use (&$checks): void {
        $checks[] = [
            'name' => $name,
            'status' => in_array($status, ['pass', 'warn', 'fail'], true) ? $status : 'warn',
            'message' => $message,
            'context' => $context,
        ];
    };
    $capture = function (string $name, string $level, callable $check) use ($record): void {
        try {
            [$ok, $message, $context] = array_pad($check(), 3, []);
        } catch (Throwable $e) {
            $ok = false;
            $message = $e->getMessage();
            $context = ['exception' => get_class($e)];
        }

        $record($name, (bool) $ok ? 'pass' : $level, (string) $message, is_array($context) ? $context : []);
    };
    $ageSeconds = function (mixed $timestamp): ?int {
        if (! is_string($timestamp) || trim($timestamp) === '') {
            return null;
        }

        try {
            return (int) Carbon::parse($timestamp)->diffInSeconds(now());
        } catch (Throwable) {
            return null;
        }
    };
    $schedulerFresh = function (string $key, int $maxAgeSeconds) use ($ageSeconds): bool {
        $age = $ageSeconds(Cache::get($key));

        return $age !== null && $age <= $maxAgeSeconds;
    };

    $capture('APP_ENV', $strict ? 'fail' : 'warn', fn (): array => [
        app()->environment('production'),
        app()->environment('production') ? 'APP_ENV is production.' : 'APP_ENV is not production; use production for a real deployment.',
        ['environment' => app()->environment()],
    ]);
    $capture('APP_DEBUG disabled', 'fail', fn (): array => [
        ! (bool) config('app.debug'),
        (bool) config('app.debug') ? 'Set APP_DEBUG=false before exposing the backend.' : 'APP_DEBUG is false.',
    ]);
    $capture('APP_KEY configured', 'fail', function () use ($configured): array {
        $key = trim((string) config('app.key'));
        $ok = $configured($key, ['base64:your-app-key-here']) && strlen($key) >= 32;

        return [
            $ok,
            $ok
                ? 'APP_KEY is configured; JWT signing material exists.'
                : 'APP_KEY is required because JWT access tokens are signed from the app key.',
        ];
    });
    $capture('Mock data disabled', $strict ? 'fail' : 'warn', fn (): array => [
        ! (bool) config('pioneer.show_mock_data', false),
        (bool) config('pioneer.show_mock_data', false)
            ? 'Mock data is enabled for demo mode; run --strict before real production publishing.'
            : 'Mock data flag is disabled.',
    ]);
    $capture('Frontend URL configured', $strict ? 'fail' : 'warn', function () use ($configured): array {
        $ok = $configured(config('pioneer.frontend_url'));

        return [
            $ok,
            $ok
                ? 'PIONEER_FRONTEND_URL is configured.'
                : 'PIONEER_FRONTEND_URL should be set once the production domain exists.',
            ['frontendUrl' => config('pioneer.frontend_url')],
        ];
    });
    $capture('CORS origins configured', $strict ? 'fail' : 'warn', function () use ($configured): array {
        $origins = array_values(array_filter(array_map('trim', explode(',', (string) config('pioneer.cors_allowed_origins', '')))));
        $safe = $origins !== [] && ! in_array('*', $origins, true) && collect($origins)->every(fn (string $origin): bool => $configured($origin));

        return [
            $safe,
            $safe ? 'CORS origins are explicit.' : 'Set PIONEER_CORS_ALLOWED_ORIGINS to explicit production origins.',
            ['origins' => $origins],
        ];
    });
    $capture('Database reachable', 'fail', function (): array {
        DB::connection()->getPdo();

        return [true, 'Database connection is reachable.', ['connection' => config('database.default')]];
    });
    $capture('No pending migrations', 'fail', function (): array {
        $migrator = app('migrator');
        $files = $migrator->getMigrationFiles(database_path('migrations'));
        $ran = $migrator->getRepository()->getRan();
        $pending = array_values(array_diff(array_keys($files), $ran));

        return [
            count($pending) === 0,
            count($pending) === 0 ? 'All migrations have run.' : count($pending).' migration(s) are pending.',
            ['pending' => array_slice($pending, 0, 10)],
        ];
    });
    $capture('Redis cache configured', 'fail', function (): array {
        if (config('cache.default') !== 'redis') {
            return [false, 'CACHE_STORE must be redis for production snapshots and scheduler locks.', ['cacheStore' => config('cache.default')]];
        }

        Cache::store('redis')->put('pioneer_production_gate_cache', 'ok', 30);

        return [
            Cache::store('redis')->get('pioneer_production_gate_cache') === 'ok',
            'Redis cache store read/write completed.',
            ['cacheStore' => config('cache.default')],
        ];
    });
    $capture('Redis queue configured', 'fail', fn (): array => [
        config('queue.default') === 'redis',
        config('queue.default') === 'redis' ? 'Queue connection is redis.' : 'QUEUE_CONNECTION must be redis.',
        ['queueConnection' => config('queue.default')],
    ]);
    $capture('Queue worker processing', 'fail', function (): array {
        Artisan::call('pioneer:queue-check', ['--json' => true, '--wait' => 2]);
        $payload = json_decode(Artisan::output(), true);
        $ok = is_array($payload) && (bool) ($payload['ok'] ?? false);

        return [
            $ok,
            $ok
                ? 'Queue worker processed a health probe or has fresh processing state.'
                : 'Queue worker did not process a health probe; run php artisan queue:work redis under a process manager.',
            is_array($payload) ? $payload : [],
        ];
    });
    $capture('Scheduler feed sync fresh', 'fail', fn (): array => [
        $schedulerFresh('geotab_scheduler_last_run_geotab_feed_sync', 600),
        'geotab:feed-sync must run within the last 10 minutes.',
        ['cacheKey' => 'geotab_scheduler_last_run_geotab_feed_sync'],
    ]);
    $capture('Scheduler snapshot warm fresh', 'fail', fn (): array => [
        $schedulerFresh('geotab_scheduler_last_run_geotab_snapshot_warm', 300),
        'geotab:snapshot-warm must run within the last 5 minutes.',
        ['cacheKey' => 'geotab_scheduler_last_run_geotab_snapshot_warm'],
    ]);
    $capture('Scheduler writeback fresh', 'fail', fn (): array => [
        $schedulerFresh('geotab_scheduler_last_run_geotab_writeback_process', 300),
        'geotab:writeback-process must run within the last 5 minutes.',
        ['cacheKey' => 'geotab_scheduler_last_run_geotab_writeback_process'],
    ]);
    $capture('GeoTab diagnosis', 'fail', function (): array {
        /** @var GeotabFeedHarvester $harvester */
        $harvester = app(GeotabFeedHarvester::class);
        $diagnosis = $harvester->health()['emptyDataDiagnosis'] ?? [];
        $status = (string) ($diagnosis['status'] ?? 'unknown');
        $reason = (string) ($diagnosis['primaryReason'] ?? 'unknown');

        return [
            $status !== 'blocked',
            'GeoTab diagnosis status='.$status.' reason='.$reason.'.',
            ['status' => $status, 'primaryReason' => $reason],
        ];
    });
    $capture('Backup freshness', 'fail', function (): array {
        /** @var PioneerBackupHealthService $backups */
        $backups = app(PioneerBackupHealthService::class);
        $result = $backups->check();
        $latestFile = (string) ($result['latestFile'] ?? '');
        $isDemoMarker = str_contains(Str::lower($latestFile), 'demo-marker');
        $ok = ($result['ok'] ?? false) === true && (! $this->option('strict') || ! $isDemoMarker);

        return [
            $ok,
            $isDemoMarker && $this->option('strict')
                ? 'Demo backup marker is not a real database dump. Run a real backup before strict production publishing.'
                : (string) ($result['message'] ?? 'Backup check failed.'),
            [
                'status' => $result['status'] ?? 'unknown',
                'latestFile' => $result['latestFile'] ?? null,
                'ageHours' => $result['ageHours'] ?? null,
                'maxAgeHours' => $result['maxAgeHours'] ?? null,
                'demoMarker' => $isDemoMarker,
            ],
        ];
    });
    $capture('Core API routes registered', 'fail', function (): array {
        $registered = collect(Route::getRoutes())
            ->map(fn ($route): string => trim((string) $route->uri(), '/'))
            ->values()
            ->all();
        $required = [
            'api/health',
            'api/fleet/live',
            'api/fleet/summary',
            'api/fleet/summary/live',
            'api/fleet/geotab/health',
            'api/fleet/users/login-check',
            'api/fleet/auth/refresh',
            'api/fleet/geotab/writeback/jobs',
        ];
        $missing = array_values(array_diff($required, $registered));

        return [
            $missing === [],
            $missing === [] ? 'Core API routes are registered.' : 'Missing required API route(s): '.implode(', ', $missing).'.',
            ['missing' => $missing],
        ];
    });
    $capture('Performance readiness', 'fail', function (): array {
        Artisan::call('pioneer:performance-check', ['--json' => true]);
        $payload = json_decode(Artisan::output(), true);
        $summary = is_array($payload['summary'] ?? null) ? $payload['summary'] : [];

        return [
            (int) ($summary['failed'] ?? 1) === 0,
            sprintf(
                'Performance check passed=%d warnings=%d failed=%d.',
                (int) ($summary['passed'] ?? 0),
                (int) ($summary['warnings'] ?? 0),
                (int) ($summary['failed'] ?? 1),
            ),
            $summary,
        ];
    });

    $summary = [
        'passed' => collect($checks)->where('status', 'pass')->count(),
        'warnings' => collect($checks)->where('status', 'warn')->count(),
        'failed' => collect($checks)->where('status', 'fail')->count(),
        'strict' => $strict,
    ];
    $payload = ['summary' => $summary, 'checks' => $checks];

    if ($this->option('json')) {
        $this->line(json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));

        return $summary['failed'] > 0 ? 1 : 0;
    }

    foreach ($checks as $check) {
        $label = match ($check['status']) {
            'pass' => '[PASS]',
            'fail' => '[FAIL]',
            default => '[WARN]',
        };
        $this->line(sprintf('%s %s - %s', $label, $check['name'], $check['message']));
    }

    if ($summary['failed'] > 0) {
        $this->error($summary['failed'].' production gate blocker(s) found.');

        return 1;
    }

    $this->info('PioneerPath production gate passed with '.$summary['warnings'].' warning(s).');

    return 0;
})->purpose('Run the final backend production readiness gate before deployment.');

Artisan::command('pioneer:setup-check', function () {
    $checks = [];
    $add = function (string $name, bool $ok, string $message, string $category): void {
        $this->line(sprintf(
            '%s %s [%s] - %s',
            $ok ? '[PASS]' : '[FAIL]',
            $name,
            $ok ? 'CODE READY' : $category,
            $message
        ));
    };
    $capture = function (string $name, callable $check, string $category = 'CODE READY') use (&$checks): void {
        try {
            [$ok, $message] = $check();
        } catch (Throwable $e) {
            $ok = false;
            $message = $e->getMessage();
        }
        $checks[] = ['name' => $name, 'ok' => (bool) $ok, 'message' => (string) $message, 'category' => $category];
    };
    $configured = function (?string $value, array $placeholders = []): bool {
        $value = trim((string) $value);
        if ($value === '') {
            return false;
        }

        $lower = Str::lower($value);
        foreach ($placeholders as $placeholder) {
            if ($lower === Str::lower($placeholder) || str_contains($lower, 'your-') || str_contains($lower, 'placeholder')) {
                return false;
            }
        }

        return true;
    };

    $capture('APP_DEBUG', fn (): array => [
        ! (bool) config('app.debug'),
        (bool) config('app.debug') ? 'Set APP_DEBUG=false for production.' : 'Production debug mode is disabled.',
    ]);
    $capture('APP_KEY', fn (): array => [
        $configured((string) config('app.key'), ['base64:your-app-key-here']),
        'APP_KEY must be generated with php artisan key:generate.',
    ]);
    $capture('Database', function (): array {
        if (config('database.default') !== 'mysql') {
            return [false, 'DB_CONNECTION must be mysql.'];
        }
        DB::connection()->getPdo();

        return [true, 'MySQL connection is reachable.'];
    });
    $capture('Cache', function (): array {
        $driver = (string) config('cache.default');
        if ($driver !== 'redis') {
            return [false, 'CACHE_DRIVER/CACHE_STORE must be redis.'];
        }
        Cache::store('redis')->put('pioneer_setup_check', 'ok', 30);

        return [Cache::store('redis')->get('pioneer_setup_check') === 'ok', 'Redis cache read/write check completed.'];
    }, 'NEEDS DEPLOYMENT CONFIG');
    $capture('Queue', fn (): array => [
        config('queue.default') === 'redis',
        config('queue.default') === 'redis' ? 'Queue connection is redis.' : 'QUEUE_CONNECTION must be redis.',
    ], 'NEEDS DEPLOYMENT CONFIG');
    $capture('GeoTab Credentials', fn (): array => [
        $configured(config('geotab.database'))
            && $configured(config('geotab.username'))
            && $configured(config('geotab.password'))
            && $configured(config('geotab.server'), ['my.geotab.com']),
        'GEOTAB_DATABASE, GEOTAB_USERNAME, GEOTAB_PASSWORD, and GEOTAB_SERVER must be real production values.',
    ], 'NEEDS DEPLOYMENT CONFIG');
    $capture('VAPID Keys', fn (): array => [
        $configured(config('services.web_push.public_key'), ['your-vapid-public-key-here'])
            && $configured(config('services.web_push.private_key'), ['your-vapid-private-key-here'])
            && $configured(config('services.web_push.subject'), ['mailto:admin@yourcompany.com']),
        'VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, and VAPID_SUBJECT must be configured.',
    ], 'NEEDS DEPLOYMENT CONFIG');
    $capture('Google Maps', function () use ($configured): array {
        $enabled = (bool) config('services.google_maps.enrichment_enabled', false);
        if (! $enabled) {
            return [true, 'Google enrichment is disabled; map rendering key can still be supplied separately.'];
        }

        return [
            $configured(config('services.google_maps.server_key')) || $configured(config('services.google_maps.browser_key')),
            'GOOGLE_MAPS_SERVER_KEY or GOOGLE_MAPS_API_KEY is required when enrichment is enabled.',
        ];
    });
    $capture('Mail', fn (): array => [
        $configured(config('mail.default'))
            && config('mail.default') !== 'log'
            && $configured(config('mail.from.address'), ['hello@example.com']),
        'Configure MAIL_* for real password reset emails and alerts.',
    ], 'NEEDS DEPLOYMENT CONFIG');
    $capture('Migrations', function (): array {
        $migrator = app('migrator');
        $files = $migrator->getMigrationFiles(database_path('migrations'));
        $ran = $migrator->getRepository()->getRan();
        $pending = array_diff(array_keys($files), $ran);

        return [count($pending) === 0, count($pending) === 0 ? 'All migrations have run.' : count($pending).' migration(s) are pending.'];
    });
    $capture('GeoTab Feed Seeded', fn (): array => [
        Schema::hasTable('geotab_feed_checkpoints')
            && GeotabFeedCheckpoint::query()
                ->where(function ($query): void {
                    $query->whereNotNull('seeded_at')->orWhereNotNull('last_success_at');
                })
                ->exists(),
        'Run php artisan geotab:feed-seed before production traffic.',
    ]);

    foreach ($checks as $check) {
        $add($check['name'], $check['ok'], $check['message'], $check['category']);
    }

    $failed = collect($checks)->where('ok', false)->count();
    if ($failed > 0) {
        $this->error($failed.' setup check(s) failed.');

        return 1;
    }

    $this->info('PioneerPath production setup check passed.');

    return 0;
})->purpose('Validate PioneerPath production environment configuration before deployment.');

Artisan::command('pioneer:backup-demo-mark {--path= : Override the configured demo backup path}', function () {
    $path = trim((string) ($this->option('path') ?: config('pioneer.backups.path', storage_path('app/backups'))));
    if ($path === '') {
        $this->error('Backup path is empty.');

        return 1;
    }

    $normalizedPublic = str_replace('\\', '/', realpath(public_path()) ?: public_path());
    $normalizedPath = str_replace('\\', '/', $path);
    if (str_starts_with($normalizedPath, $normalizedPublic)) {
        $this->error('Refusing to create a backup marker inside the public web root.');

        return 1;
    }

    if (! is_dir($path) && ! mkdir($path, 0755, true) && ! is_dir($path)) {
        $this->error('Unable to create backup path: '.$path);

        return 1;
    }

    $file = rtrim($path, DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR.'pioneerpath-demo-marker-'.now()->format('Ymd-His').'.sql.gz';
    $body = implode("\n", [
        '-- PioneerPath demo backup marker.',
        '-- This is not a database dump.',
        '-- It exists only so demo/local readiness checks can prove backup path freshness.',
        '-- Run a real MySQL backup before strict production publishing.',
        'created_at='.now()->toIso8601String(),
        '',
    ]);

    if (file_put_contents($file, $body) === false) {
        $this->error('Unable to write demo backup marker: '.$file);

        return 1;
    }

    $this->warn('Created a demo backup marker, not a real database dump.');
    $this->line('marker='.$file);
    $this->line('strict_production_note=Run a real MySQL backup before php artisan pioneer:production-gate --strict.');

    return 0;
})->purpose('Create a clearly marked demo backup freshness file outside the public web root.');

Artisan::command('pioneer:backup-check', function () {
    /** @var PioneerBackupHealthService $backups */
    $backups = app(PioneerBackupHealthService::class);
    $result = $backups->check();
    $backups->logResult($result);
    $backups->alertSuperAdministrators($result);

    $this->line(sprintf(
        'backup_status=%s latest=%s age_hours=%s max_age_hours=%s',
        (string) ($result['status'] ?? 'unknown'),
        (string) ($result['latestFile'] ?? 'none'),
        $result['ageHours'] === null ? 'n/a' : (string) $result['ageHours'],
        (string) ($result['maxAgeHours'] ?? 'n/a'),
    ));

    if (($result['ok'] ?? false) !== true) {
        $this->error((string) ($result['message'] ?? 'Backup check failed.'));

        return 1;
    }

    $this->info((string) ($result['message'] ?? 'Backup check passed.'));

    return 0;
})->purpose('Verify the most recent PioneerPath database backup is present and fresh.');

Artisan::command('pioneer:integrity-check', function () {
    /** @var PioneerIntegrityCheckService $integrity */
    $integrity = app(PioneerIntegrityCheckService::class);
    $result = $integrity->check();
    $integrity->logResult($result);

    $counts = is_array($result['counts'] ?? null) ? $result['counts'] : [];
    foreach ($counts as $name => $count) {
        $this->line(sprintf('%s=%d', (string) $name, (int) $count));
    }

    if (($result['ok'] ?? false) !== true) {
        $this->error('Integrity check found data anomalies. See storage/logs/integrity.log for details.');

        return 1;
    }

    $this->info('Integrity check passed with no anomalies.');

    return 0;
})->purpose('Report PioneerPath invoice, GPS, write-back, and active-trip consistency anomalies without modifying data.');
