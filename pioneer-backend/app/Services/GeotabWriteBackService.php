<?php

namespace App\Services;

use App\Jobs\SendCriticalNotificationEmail;
use App\Models\FleetRoute;
use App\Models\FleetRouteStop;
use App\Models\FleetZone;
use App\Models\GeotabWriteJob;
use App\Models\MaintenanceHistory;
use App\Models\ManualDriver;
use App\Models\ManualVehicle;
use App\Models\NotificationHistory;
use App\Models\SystemSetting;
use App\Models\User;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

class GeotabWriteBackService
{
    private const MAX_ATTEMPTS = 5;

    public function __construct(private readonly GeotabService $geotab) {}

    public function tableAvailable(): bool
    {
        return Schema::hasTable('geotab_write_jobs');
    }

    public function createJob(
        string $action,
        string $entityType,
        array $payload,
        ?string $localType = null,
        ?string $localId = null,
        ?string $idempotencyKey = null,
        string $createdBy = 'system',
        ?array $previewPayload = null,
    ): ?GeotabWriteJob {
        if (! $this->tableAvailable()) {
            return null;
        }

        $key = $idempotencyKey ?: sha1($action.'|'.$entityType.'|'.$localType.'|'.$localId.'|'.json_encode($payload));

        $job = GeotabWriteJob::query()->firstOrCreate(
            ['idempotency_key' => $key],
            [
                'action' => $action,
                'entity_type' => $entityType,
                'local_type' => $localType,
                'local_id' => $localId,
                'payload' => $payload,
                'preview_payload' => $previewPayload,
                'status' => 'pending_approval',
                'attempts' => 0,
                'max_attempts' => self::MAX_ATTEMPTS,
                'created_by' => $createdBy,
                'audit_trail' => [
                    $this->auditEvent('created', $createdBy, [
                        'action' => $action,
                        'entityType' => $entityType,
                        'localType' => $localType,
                        'localId' => $localId,
                    ]),
                ],
            ],
        );
        $this->publishWriteBackStatus($job->refresh());

        return $job;
    }

    public function approve(GeotabWriteJob $job, string $approvedBy = 'system'): GeotabWriteJob
    {
        if (! in_array($job->status, ['pending_approval', 'failed'], true)) {
            return $job;
        }

        $job->forceFill([
            'status' => 'approved',
            'approved_by' => $approvedBy,
            'approved_at' => now(),
            'next_attempt_at' => null,
            'last_error' => null,
        ])->save();

        $this->appendAudit($job, 'approved', $approvedBy);
        $this->queueReviewNotification($job->refresh(), 'approved');
        $this->publishWriteBackStatus($job->refresh());

        return $job->refresh();
    }

    public function retry(GeotabWriteJob $job, string $actor = 'admin'): GeotabWriteJob
    {
        if (! in_array($job->status, ['failed', 'cancelled', 'permanently_failed'], true)) {
            return $job;
        }

        $job->forceFill([
            'status' => 'pending_approval',
            'last_error' => null,
            'next_attempt_at' => null,
            'permanently_failed_at' => null,
        ])->save();

        $this->appendAudit($job, 'manual_retry_requested', $actor);
        $this->publishWriteBackStatus($job->refresh());

        return $job->refresh();
    }

    public function reject(GeotabWriteJob $job, string $reason, string $actor = 'admin'): GeotabWriteJob
    {
        if (in_array($job->status, ['succeeded', 'processing'], true)) {
            return $job;
        }

        $reason = trim($reason);
        $job->forceFill([
            'status' => 'rejected',
            'last_error' => $reason,
            'next_attempt_at' => null,
        ])->save();

        $this->appendAudit($job, 'rejected', $actor, ['reason' => $reason]);
        $this->markLocalRejected($job, $reason);
        $this->queueReviewNotification($job->refresh(), 'rejected', $reason);
        $this->publishWriteBackStatus($job->refresh());

        return $job->refresh();
    }

    public function cancel(GeotabWriteJob $job, string $reason = '', string $actor = 'admin'): GeotabWriteJob
    {
        return $this->reject($job, $reason !== '' ? $reason : 'Rejected by admin.', $actor);
    }

    public function deleteWithoutExecution(GeotabWriteJob $job): bool
    {
        if (in_array($job->status, ['approved', 'processing', 'succeeded'], true)) {
            return false;
        }

        $this->clearDeletedJobLocalState($job);
        $job->delete();

        return true;
    }

    public function processApproved(int $limit = 10): array
    {
        if (! $this->tableAvailable()) {
            return ['processed' => 0, 'succeeded' => 0, 'failed' => 0, 'skipped' => 0];
        }

        $summary = ['processed' => 0, 'succeeded' => 0, 'failed' => 0, 'skipped' => 0];
        $jobs = $this->processableJobsQuery()
            ->orderBy('approved_at')
            ->orderBy('next_attempt_at')
            ->limit($limit)
            ->get();

        foreach ($jobs as $job) {
            $summary['processed']++;
            $processed = $this->process($job);
            if ($processed->status === 'succeeded') {
                $summary['succeeded']++;
            } elseif ($processed->status === 'failed') {
                $summary['failed']++;
            } else {
                $summary['skipped']++;
            }
        }

        return $summary;
    }

    public function process(GeotabWriteJob $job, array $runtimeSecrets = []): GeotabWriteJob
    {
        if (! in_array($job->status, ['approved', 'processing', 'failed'], true)) {
            return $job;
        }

        $job->forceFill([
            'status' => 'processing',
            'attempts' => $job->attempts + 1,
            'last_attempt_at' => now(),
            'next_attempt_at' => null,
            'last_error' => null,
        ])->save();
        $this->appendAudit($job, 'execution_started', 'system', [
            'attempt' => (int) $job->attempts,
        ]);
        Log::channel('write_back')->info('pioneerpath.writeback.execution_started', [
            'jobId' => $job->id,
            'action' => $job->action,
            'entityType' => $job->entity_type,
            'attempt' => (int) $job->attempts,
        ]);

        try {
            $payload = is_array($job->payload) ? $job->payload : [];
            $result = str_starts_with((string) $job->action, 'group.')
                ? $this->processGroupedWriteBack($payload, $runtimeSecrets)
                : $this->executeWriteBackAction($job->action, $payload, $runtimeSecrets);

            $job->forceFill([
                'status' => 'succeeded',
                'geotab_id' => (string) ($result['geotabId'] ?? $job->geotab_id ?? ''),
                'result' => $result,
                'processed_at' => now(),
                'next_attempt_at' => null,
            ])->save();

            $this->appendAudit($job, 'succeeded', 'system', [
                'attempt' => (int) $job->attempts,
                'geotabId' => (string) ($result['geotabId'] ?? $job->geotab_id ?? ''),
            ]);
            Log::channel('write_back')->info('pioneerpath.writeback.succeeded', [
                'jobId' => $job->id,
                'action' => $job->action,
                'entityType' => $job->entity_type,
                'attempt' => (int) $job->attempts,
                'geotabId' => (string) ($result['geotabId'] ?? $job->geotab_id ?? ''),
            ]);
            $this->markLocalSynced($job, $result);
            $this->publishWriteBackStatus($job->refresh());
        } catch (\Throwable $e) {
            $attempt = (int) $job->attempts;
            $permanent = $attempt >= (int) $job->max_attempts;
            $nextAttemptAt = $permanent ? null : $this->nextAttemptAt($attempt);
            $job->forceFill([
                'status' => $permanent ? 'permanently_failed' : 'failed',
                'last_error' => $e->getMessage(),
                'processed_at' => now(),
                'next_attempt_at' => $nextAttemptAt,
                'permanently_failed_at' => $permanent ? now() : null,
            ])->save();
            $this->appendAudit($job, $permanent ? 'permanently_failed' : 'failed', 'system', [
                'attempt' => $attempt,
                'error' => Str::limit($e->getMessage(), 1000, ''),
                'nextAttemptAt' => $nextAttemptAt?->toIso8601String(),
            ]);
            Log::channel('write_back')->warning('pioneerpath.writeback.failed', [
                'jobId' => $job->id,
                'action' => $job->action,
                'entityType' => $job->entity_type,
                'attempt' => $attempt,
                'permanent' => $permanent,
                'nextAttemptAt' => $nextAttemptAt?->toIso8601String(),
                'error' => Str::limit($e->getMessage(), 1000, ''),
            ]);
            if ($permanent) {
                $this->queuePermanentFailureEmail($job, $e->getMessage());
            }
            $this->markLocalFailed($job, $e->getMessage());
            $this->publishWriteBackStatus($job->refresh());
        }

        return $job->refresh();
    }

    public function health(): array
    {
        if (! $this->tableAvailable()) {
            return [
                'tableAvailable' => false,
                'pendingApproval' => 0,
                'approved' => 0,
                'failed' => 0,
                'succeeded' => 0,
                'oldestPendingAgeSeconds' => null,
                'lastSuccess' => null,
                'lastFailure' => null,
                'lastFailureMessage' => null,
                'totalPendingJobs' => 0,
                'totalApprovedAwaitingExecution' => 0,
                'totalFailedJobs' => 0,
                'totalCompletedToday' => 0,
                'lastSuccessfulWriteBackTimestamp' => null,
                'lastFailedWriteBackError' => null,
            ];
        }

        $oldest = GeotabWriteJob::query()
            ->whereIn('status', ['pending_approval', 'approved'])
            ->oldest()
            ->first();
        $lastSuccess = GeotabWriteJob::query()->where('status', 'succeeded')->latest('processed_at')->first();
        $lastFailure = GeotabWriteJob::query()->whereIn('status', ['failed', 'permanently_failed'])->latest('processed_at')->first();
        $pendingApproval = GeotabWriteJob::query()->where('status', 'pending_approval')->count();
        $approved = GeotabWriteJob::query()->where('status', 'approved')->count();
        $failed = GeotabWriteJob::query()->whereIn('status', ['failed', 'permanently_failed'])->count();
        $succeeded = GeotabWriteJob::query()->where('status', 'succeeded')->count();
        $completedToday = GeotabWriteJob::query()
            ->where('status', 'succeeded')
            ->whereDate('processed_at', now()->toDateString())
            ->count();

        return [
            'tableAvailable' => true,
            'pendingApproval' => $pendingApproval,
            'approved' => $approved,
            'failed' => $failed,
            'succeeded' => $succeeded,
            'oldestPendingAgeSeconds' => $oldest?->created_at?->diffInSeconds(now()),
            'lastSuccess' => $lastSuccess?->processed_at?->toIso8601String(),
            'lastFailure' => $lastFailure?->processed_at?->toIso8601String(),
            'lastFailureMessage' => $lastFailure?->last_error,
            'totalPendingJobs' => $pendingApproval,
            'totalApprovedAwaitingExecution' => $approved,
            'totalFailedJobs' => $failed,
            'totalCompletedJobsToday' => $completedToday,
            'lastSuccessfulWriteBackTimestamp' => $lastSuccess?->processed_at?->toIso8601String(),
            'lastFailedWriteBackTimestamp' => $lastFailure?->processed_at?->toIso8601String(),
            'lastFailedWriteBackError' => $lastFailure?->last_error,
        ];
    }

    private function processableJobsQuery(): Builder
    {
        return GeotabWriteJob::query()
            ->whereColumn('attempts', '<', 'max_attempts')
            ->where(function (Builder $query): void {
                $query->where('status', 'approved')
                    ->orWhere('status', 'failed');
            })
            ->where(function (Builder $query): void {
                $query->where('status', 'approved')
                    ->orWhereNull('next_attempt_at')
                    ->orWhere('next_attempt_at', '<=', now()->toDateTimeString());
            });
    }

    private function nextAttemptAt(int $attempt): Carbon
    {
        $minutes = match ($attempt) {
            1 => 1,
            2 => 5,
            3 => 30,
            default => 120,
        };

        return now()->addMinutes($minutes);
    }

    private function createDriver(array $payload, array $runtimeSecrets): array
    {
        $entity = $payload['entity'] ?? [];
        if (! is_array($entity)) {
            $entity = [];
        }

        $password = trim((string) ($runtimeSecrets['temporaryPassword'] ?? ''));
        if ($password === '') {
            throw new \RuntimeException('A temporary password is required to create a MyGeotab driver.');
        }

        $entity['password'] = $password;
        $entity['isDriver'] = true;
        $id = $this->geotab->addEntity('User', $entity);

        return ['geotabId' => $id, 'typeName' => 'User'];
    }

    private function executeWriteBackAction(string $action, array $payload, array $runtimeSecrets = []): array
    {
        return match ($action) {
            'driver.create' => $this->createDriver($payload, $runtimeSecrets),
            'driver.update' => $this->updateDriver($payload),
            'driver.deactivate' => $this->deactivateDriver($payload),
            'route.create' => $this->createRoute($payload),
            'route.update' => $this->updateRoute($payload),
            'route.assign_device' => $this->assignRouteDevice($payload),
            'route.remove' => $this->removeRoute($payload),
            'zone.create' => $this->createZone($payload),
            'zone.update' => $this->updateZone($payload),
            'zone.remove' => $this->removeZone($payload),
            'vehicle.update_device' => $this->updateVehicleDevice($payload),
            'maintenance.reminder' => $this->createMaintenanceReminder($payload),
            default => throw new \RuntimeException('Unsupported GeoTab write-back action: '.$action),
        };
    }

    private function processGroupedWriteBack(array $payload, array $runtimeSecrets = []): array
    {
        $operations = $payload['operations'] ?? [];
        if (! is_array($operations) || $operations === []) {
            throw new \RuntimeException('Grouped GeoTab write-back has no operations to process.');
        }

        $completed = [];
        $results = [];
        try {
            foreach ($operations as $index => $operation) {
                if (! is_array($operation)) {
                    continue;
                }

                $action = trim((string) ($operation['action'] ?? ''));
                $operationPayload = $operation['payload'] ?? [];
                if ($action === '' || ! is_array($operationPayload)) {
                    throw new \RuntimeException('Grouped GeoTab write-back contains an invalid operation.');
                }

                $operationPayload = $this->resolveGroupedOperationPayload($action, $operationPayload, $results);
                $localSnapshotPayload = is_array($operation['localSnapshotPayload'] ?? null)
                    ? $this->resolveGroupedOperationPayload($action, (array) $operation['localSnapshotPayload'], $results)
                    : $operationPayload;
                $result = $this->executeWriteBackAction($action, $operationPayload, $runtimeSecrets);
                $completed[] = [
                    'action' => $action,
                    'payload' => $operationPayload,
                    'snapshot' => is_array($operation['snapshot'] ?? null) ? $operation['snapshot'] : [],
                    'result' => $result,
                ];
                $results[] = [
                    'index' => $index,
                    'action' => $action,
                    'localType' => (string) ($operation['localType'] ?? ''),
                    'localId' => (string) ($operation['localId'] ?? ''),
                    'resolvedPayload' => $operationPayload,
                    'resolvedLocalSnapshotPayload' => $localSnapshotPayload,
                    'result' => $result,
                ];
            }
        } catch (\Throwable $e) {
            $this->rollbackGroupedWriteBack($completed);

            throw $e;
        }

        return [
            'geotabId' => (string) data_get($results, '0.result.geotabId', ''),
            'typeName' => 'GroupedWriteBack',
            'operationResults' => $results,
        ];
    }

    private function resolveGroupedOperationPayload(string $action, array $payload, array $results): array
    {
        $payload = $this->resolveRoutePlanItemZoneReferences($payload, $results);

        if (in_array($action, ['route.create', 'route.update'], true)) {
            return $payload;
        }

        if ($action !== 'route.assign_device') {
            return $payload;
        }

        $routeId = trim((string) ($payload['routeId'] ?? ''));
        if ($routeId !== '' && ! in_array($routeId, ['$previous.geotabId', '__previous_geotab_id__'], true)) {
            return $payload;
        }

        $previousRoute = collect($results)
            ->reverse()
            ->first(fn (array $item): bool => in_array((string) ($item['action'] ?? ''), ['route.create', 'route.update'], true)
                && trim((string) data_get($item, 'result.geotabId', '')) !== '');

        $previousRouteId = trim((string) data_get($previousRoute, 'result.geotabId', ''));
        if ($previousRouteId !== '') {
            $payload['routeId'] = $previousRouteId;
        }

        return $payload;
    }

    private function resolveRoutePlanItemZoneReferences(array $payload, array $results): array
    {
        foreach ((array) ($payload['planItems'] ?? []) as $index => $item) {
            if (! is_array($item)) {
                continue;
            }

            $zoneId = trim((string) data_get($item, 'zone.id', ''));
            if (! str_starts_with($zoneId, '$previous.zone:')) {
                continue;
            }

            $stopId = substr($zoneId, strlen('$previous.zone:'));
            $previousZone = collect($results)
                ->reverse()
                ->first(fn (array $result): bool => (string) ($result['action'] ?? '') === 'zone.create'
                    && (string) ($result['localType'] ?? '') === 'fleet_route_stop'
                    && (string) ($result['localId'] ?? '') === $stopId
                    && trim((string) data_get($result, 'result.geotabId', '')) !== '');
            $resolvedZoneId = trim((string) data_get($previousZone, 'result.geotabId', ''));
            if ($resolvedZoneId !== '') {
                $payload['planItems'][$index]['zone']['id'] = $resolvedZoneId;
            }
        }

        return $payload;
    }

    private function rollbackGroupedWriteBack(array $completed): void
    {
        foreach (array_reverse($completed) as $operation) {
            try {
                $this->rollbackCompletedOperation($operation);
            } catch (\Throwable $rollbackError) {
                Log::channel('write_back')->warning('pioneerpath.writeback.group_rollback_failed', [
                    'action' => (string) ($operation['action'] ?? ''),
                    'error' => Str::limit($rollbackError->getMessage(), 1000, ''),
                ]);
            }
        }
    }

    private function rollbackCompletedOperation(array $operation): void
    {
        $action = (string) ($operation['action'] ?? '');
        $snapshot = is_array($operation['snapshot'] ?? null) ? $operation['snapshot'] : [];
        $result = is_array($operation['result'] ?? null) ? $operation['result'] : [];

        if ($action === 'driver.create') {
            $createdId = trim((string) ($result['geotabId'] ?? ''));
            if ($createdId !== '') {
                $this->geotab->removeEntity('User', ['id' => $createdId]);
            }

            return;
        }

        if (in_array($action, ['driver.update', 'driver.deactivate'], true)) {
            $entity = $snapshot['entity'] ?? [];
            if (is_array($entity) && trim((string) ($entity['id'] ?? '')) !== '') {
                $this->geotab->setEntity('User', $entity);
            }

            return;
        }

        if ($action === 'vehicle.update_device') {
            $entity = $snapshot['entity'] ?? [];
            if (is_array($entity) && trim((string) ($entity['id'] ?? '')) !== '') {
                $this->geotab->setEntity('Device', $entity);
            }

            return;
        }

        if ($action === 'route.create') {
            $routeId = trim((string) ($result['geotabId'] ?? ''));
            if ($routeId !== '') {
                $this->geotab->removeEntity('Route', ['id' => $routeId]);
            }

            return;
        }

        if ($action === 'route.update') {
            foreach ((array) ($result['routePlanItemIds'] ?? []) as $itemId) {
                $itemId = trim((string) $itemId);
                if ($itemId !== '') {
                    $this->geotab->removeEntity('RoutePlanItem', ['id' => $itemId]);
                }
            }
            $route = $snapshot['route'] ?? [];
            if (is_array($route) && trim((string) ($route['id'] ?? '')) !== '') {
                $this->geotab->setEntity('Route', $route);
            }

            return;
        }

        if ($action === 'route.assign_device') {
            $route = $snapshot['route'] ?? [];
            if (is_array($route) && trim((string) ($route['id'] ?? '')) !== '') {
                $this->geotab->setEntity('Route', $route);
            }

            return;
        }

        if ($action === 'zone.create') {
            $zoneId = trim((string) ($result['geotabId'] ?? ''));
            if ($zoneId !== '') {
                $this->geotab->removeEntity('Zone', ['id' => $zoneId]);
            }

            return;
        }

        if ($action === 'zone.update') {
            $zone = $snapshot['zone'] ?? [];
            if (is_array($zone) && trim((string) ($zone['id'] ?? '')) !== '') {
                $this->geotab->setEntity('Zone', $zone);
            }
        }
    }

    private function updateDriver(array $payload): array
    {
        $entity = $payload['entity'] ?? [];
        if (! is_array($entity) || trim((string) ($entity['id'] ?? '')) === '') {
            throw new \RuntimeException('A MyGeotab user id is required to update a driver.');
        }

        $entity['isDriver'] = true;
        $this->geotab->setEntity('User', $entity);

        return ['geotabId' => (string) $entity['id'], 'typeName' => 'User'];
    }

    private function deactivateDriver(array $payload): array
    {
        $entity = $payload['entity'] ?? [];
        if (! is_array($entity) || trim((string) ($entity['id'] ?? '')) === '') {
            throw new \RuntimeException('A MyGeotab user id is required to deactivate a driver.');
        }

        $entity['activeTo'] = now()->utc()->toIso8601String();
        $entity['isDriver'] = true;
        $this->geotab->setEntity('User', $entity);

        return ['geotabId' => (string) $entity['id'], 'typeName' => 'User'];
    }

    private function createRoute(array $payload): array
    {
        $route = $payload['route'] ?? [];
        $items = $payload['planItems'] ?? [];
        if (! is_array($route) || trim((string) ($route['name'] ?? '')) === '') {
            throw new \RuntimeException('Route name is required.');
        }

        $routeId = $this->geotab->addEntity('Route', $route);
        $createdItems = [];
        foreach (is_array($items) ? $items : [] as $item) {
            if (! is_array($item)) {
                continue;
            }
            $item['route'] = ['id' => $routeId];
            $createdItems[] = $this->geotab->addEntity('RoutePlanItem', $item);
        }

        return [
            'geotabId' => $routeId,
            'typeName' => 'Route',
            'routePlanItemIds' => $createdItems,
        ];
    }

    private function assignRouteDevice(array $payload): array
    {
        $routeId = trim((string) ($payload['routeId'] ?? ''));
        $deviceId = trim((string) ($payload['deviceId'] ?? ''));
        if ($routeId === '' || $deviceId === '') {
            throw new \RuntimeException('Route id and device id are required.');
        }

        $entity = [
            'id' => $routeId,
            'device' => ['id' => $deviceId],
            'routeType' => 'Plan',
        ];
        if (trim((string) ($payload['name'] ?? '')) !== '') {
            $entity['name'] = trim((string) $payload['name']);
        }

        $this->geotab->setEntity('Route', $entity);

        return ['geotabId' => $routeId, 'deviceId' => $deviceId, 'typeName' => 'Route'];
    }

    private function updateRoute(array $payload): array
    {
        $route = $payload['route'] ?? [];
        $items = $payload['planItems'] ?? [];
        $routeId = trim((string) ($route['id'] ?? ''));
        if (! is_array($route) || $routeId === '') {
            throw new \RuntimeException('A MyGeotab route id is required to update a route.');
        }

        $this->geotab->setEntity('Route', $route);
        $createdItems = [];
        foreach (is_array($items) ? $items : [] as $item) {
            if (! is_array($item)) {
                continue;
            }
            $item['route'] = ['id' => $routeId];
            $createdItems[] = $this->geotab->addEntity('RoutePlanItem', $item);
        }

        return [
            'geotabId' => $routeId,
            'typeName' => 'Route',
            'routePlanItemIds' => $createdItems,
        ];
    }

    private function removeRoute(array $payload): array
    {
        $routeId = trim((string) ($payload['routeId'] ?? ''));
        if ($routeId === '') {
            throw new \RuntimeException('A MyGeotab route id is required to remove a route.');
        }

        $this->geotab->removeEntity('Route', ['id' => $routeId]);

        return ['geotabId' => $routeId, 'typeName' => 'Route'];
    }

    private function createZone(array $payload): array
    {
        $zone = $payload['zone'] ?? [];
        if (! is_array($zone) || trim((string) ($zone['name'] ?? '')) === '' || count((array) ($zone['points'] ?? [])) < 3) {
            throw new \RuntimeException('Zone name and at least three boundary points are required.');
        }

        $zone = $this->withConfiguredZoneGroups($zone);

        Log::channel('geotab')->info('pioneerpath.geotab.zone_add.request', [
            'action' => 'zone.create',
            'zoneName' => (string) ($zone['name'] ?? ''),
            'groupIds' => array_values(array_filter(array_map(
                fn ($group): string => is_array($group) ? trim((string) ($group['id'] ?? '')) : '',
                (array) ($zone['groups'] ?? []),
            ))),
            'payload' => $zone,
        ]);

        try {
            $zoneId = $this->geotab->addEntity('Zone', $zone);
        } catch (\Throwable $error) {
            Log::channel('geotab')->warning('pioneerpath.geotab.zone_add.failed', [
                'action' => 'zone.create',
                'zoneName' => (string) ($zone['name'] ?? ''),
                'error' => Str::limit($error->getMessage(), 1000, ''),
                'payload' => $zone,
            ]);

            throw $error;
        }

        Log::channel('geotab')->info('pioneerpath.geotab.zone_add.response', [
            'action' => 'zone.create',
            'zoneName' => (string) ($zone['name'] ?? ''),
            'geotabZoneId' => $zoneId,
            'success' => $zoneId !== '',
        ]);

        if ($zoneId !== '') {
            $zone['id'] = $zoneId;
        }

        return ['geotabId' => $zoneId, 'typeName' => 'Zone', 'zone' => $zone];
    }

    private function updateZone(array $payload): array
    {
        $zone = $payload['zone'] ?? [];
        $zoneId = trim((string) ($zone['id'] ?? ''));
        if (! is_array($zone) || $zoneId === '') {
            throw new \RuntimeException('A MyGeotab zone id is required to update a zone.');
        }

        $zone = $this->withConfiguredZoneGroups($zone);

        Log::channel('geotab')->info('pioneerpath.geotab.zone_set.request', [
            'action' => 'zone.update',
            'zoneId' => $zoneId,
            'zoneName' => (string) ($zone['name'] ?? ''),
            'groupIds' => array_values(array_filter(array_map(
                fn ($group): string => is_array($group) ? trim((string) ($group['id'] ?? '')) : '',
                (array) ($zone['groups'] ?? []),
            ))),
            'payload' => $zone,
        ]);

        try {
            $this->geotab->setEntity('Zone', $zone);
        } catch (\Throwable $error) {
            Log::channel('geotab')->warning('pioneerpath.geotab.zone_set.failed', [
                'action' => 'zone.update',
                'zoneId' => $zoneId,
                'zoneName' => (string) ($zone['name'] ?? ''),
                'error' => Str::limit($error->getMessage(), 1000, ''),
                'payload' => $zone,
            ]);

            throw $error;
        }

        Log::channel('geotab')->info('pioneerpath.geotab.zone_set.response', [
            'action' => 'zone.update',
            'zoneId' => $zoneId,
            'zoneName' => (string) ($zone['name'] ?? ''),
            'success' => true,
        ]);

        return ['geotabId' => $zoneId, 'typeName' => 'Zone', 'zone' => $zone];
    }

    private function withConfiguredZoneGroups(array $zone): array
    {
        $groupId = $this->configuredGeotabCompanyGroupId();
        if ($groupId === '') {
            throw new \RuntimeException('Zone push requires GeoTab Company Group ID to be configured in Settings -> Map Settings before zones can be pushed.');
        }

        $zone['groups'] = [['id' => $groupId]];

        return $zone;
    }

    private function configuredGeotabCompanyGroupId(): string
    {
        if (Schema::hasTable('system_settings') && Schema::hasColumn('system_settings', 'geotab_default_group_id')) {
            $settingsGroup = trim((string) (SystemSetting::query()->first()?->geotab_default_group_id ?? ''));
            if ($settingsGroup !== '') {
                return $settingsGroup;
            }
        }

        return trim((string) config('services.geotab.default_group_id', ''));
    }

    private function removeZone(array $payload): array
    {
        $zoneId = trim((string) ($payload['zoneId'] ?? ''));
        if ($zoneId === '') {
            throw new \RuntimeException('A MyGeotab zone id is required to remove a zone.');
        }

        $this->geotab->removeEntity('Zone', ['id' => $zoneId]);

        return ['geotabId' => $zoneId, 'typeName' => 'Zone'];
    }

    private function updateVehicleDevice(array $payload): array
    {
        $entity = $payload['entity'] ?? [];
        if (! is_array($entity) || trim((string) ($entity['id'] ?? '')) === '') {
            throw new \RuntimeException('A MyGeotab device id is required to update a vehicle device.');
        }

        $this->geotab->setEntity('Device', $entity);

        return ['geotabId' => (string) $entity['id'], 'typeName' => 'Device'];
    }

    private function createMaintenanceReminder(array $payload): array
    {
        $entity = $payload['entity'] ?? [];
        if (! is_array($entity) || trim((string) data_get($entity, 'device.id', '')) === '') {
            throw new \RuntimeException('A MyGeotab device id is required to create a maintenance reminder.');
        }

        $id = $this->geotab->addEntity('ReminderRule', $entity);

        return ['geotabId' => $id, 'typeName' => 'ReminderRule'];
    }

    private function markLocalSynced(GeotabWriteJob $job, array $result): void
    {
        if ($job->local_type === 'grouped_writeback') {
            foreach ($this->groupedOperations($job) as $operation) {
                $operationResult = collect((array) ($result['operationResults'] ?? []))
                    ->first(fn (array $item): bool => (string) ($item['localType'] ?? '') === (string) ($operation['localType'] ?? '')
                        && (string) ($item['localId'] ?? '') === (string) ($operation['localId'] ?? '')
                        && (string) ($item['action'] ?? '') === (string) ($operation['action'] ?? ''));
                $operationResultPayload = is_array($operationResult)
                    ? [
                        ...(array) ($operationResult['result'] ?? []),
                        'resolvedPayload' => $operationResult['resolvedPayload'] ?? null,
                        'resolvedLocalSnapshotPayload' => $operationResult['resolvedLocalSnapshotPayload'] ?? null,
                    ]
                    : [];
                $this->markGroupedOperationSynced($operation, $operationResultPayload);
            }

            return;
        }

        if ($job->local_type === 'manual_vehicle' && $job->local_id !== null && Schema::hasTable('manual_vehicles')) {
            $vehicle = ManualVehicle::query()->find($job->local_id);
            if ($vehicle !== null) {
                $vehicle->forceFill([
                    'geotab_device_id' => (string) ($result['geotabId'] ?? $vehicle->geotab_device_id ?? ''),
                    'sync_status' => 'synced',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                    'geotab_snapshot' => $job->payload,
                    'meta' => [
                        ...(is_array($vehicle->meta) ? $vehicle->meta : []),
                        'syncAction' => $job->action,
                        'syncedAt' => now()->toIso8601String(),
                    ],
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type === 'fleet_route' && $job->local_id !== null && Schema::hasTable('fleet_routes')) {
            $route = FleetRoute::query()->find($job->local_id);
            if ($route !== null) {
                $snapshotPayload = $job->payload;
                $routeId = (string) ($result['geotabId'] ?? $route->geotab_route_id ?? '');
                if ($routeId !== '' && is_array($snapshotPayload['route'] ?? null)) {
                    $snapshotPayload['route']['id'] = $routeId;
                }
                $route->forceFill([
                    'geotab_route_id' => $routeId,
                    'sync_status' => $job->action === 'route.remove' ? 'removed' : 'synced',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                    'geotab_snapshot' => $snapshotPayload,
                    'meta' => [
                        ...(is_array($route->meta) ? $route->meta : []),
                        'syncAction' => $job->action,
                        'syncedAt' => now()->toIso8601String(),
                    ],
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type === 'maintenance_history' && $job->local_id !== null && Schema::hasTable('maintenance_histories')) {
            $history = MaintenanceHistory::query()->find($job->local_id);
            if ($history !== null) {
                $history->forceFill([
                    'sync_status' => 'synced',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                    'geotab_snapshot' => $job->payload,
                    'meta' => [
                        ...(is_array($history->meta) ? $history->meta : []),
                        'syncAction' => $job->action,
                        'geotabReminderRuleId' => (string) ($result['geotabId'] ?? ''),
                        'syncedAt' => now()->toIso8601String(),
                    ],
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type === 'fleet_zone' && $job->local_id !== null && Schema::hasTable('fleet_zones')) {
            $zone = FleetZone::query()->find($job->local_id);
            if ($zone !== null) {
                $snapshotPayload = $job->payload;
                if (is_array($result['zone'] ?? null)) {
                    $snapshotPayload['zone'] = $result['zone'];
                } elseif ((string) ($result['geotabId'] ?? '') !== '' && is_array($snapshotPayload['zone'] ?? null)) {
                    $snapshotPayload['zone']['id'] = (string) $result['geotabId'];
                }
                $zone->forceFill([
                    'geotab_zone_id' => (string) ($result['geotabId'] ?? $zone->geotab_zone_id ?? ''),
                    'sync_status' => $job->action === 'zone.remove' ? 'removed' : 'synced',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                    'geotab_snapshot' => $snapshotPayload,
                    'meta' => [
                        ...(is_array($zone->meta) ? $zone->meta : []),
                        'syncAction' => $job->action,
                        'syncedAt' => now()->toIso8601String(),
                    ],
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type !== 'manual_driver' || $job->local_id === null || ! Schema::hasTable('manual_drivers')) {
            return;
        }

        $driver = ManualDriver::query()->find($job->local_id);
        if ($driver === null) {
            return;
        }

        $meta = is_array($driver->meta) ? $driver->meta : [];
        $driver->forceFill([
            'sync_status' => 'synced',
            'sync_error' => null,
            'pending_write_job_id' => null,
            'geotab_snapshot' => $job->payload,
            'meta' => [
                ...$meta,
                'syncStatus' => 'synced',
                'syncAction' => $job->action,
                'syncError' => null,
                'pendingWriteJobId' => null,
                'geotabSnapshot' => $job->payload,
                'geotabUserId' => (string) ($result['geotabId'] ?? data_get($meta, 'geotabUserId', '')),
                'syncedAt' => now()->toIso8601String(),
            ],
        ])->saveQuietly();
    }

    private function markLocalFailed(GeotabWriteJob $job, string $message): void
    {
        if ($job->local_type === 'grouped_writeback') {
            foreach ($this->groupedOperations($job) as $operation) {
                $this->markGroupedOperationFailed($operation, $message);
            }

            return;
        }

        if ($job->local_type === 'manual_vehicle' && $job->local_id !== null && Schema::hasTable('manual_vehicles')) {
            $vehicle = ManualVehicle::query()->find($job->local_id);
            if ($vehicle !== null) {
                $vehicle->forceFill([
                    'sync_status' => 'failed',
                    'sync_error' => Str::limit($message, 500, ''),
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type === 'fleet_route' && $job->local_id !== null && Schema::hasTable('fleet_routes')) {
            $route = FleetRoute::query()->find($job->local_id);
            if ($route !== null) {
                $route->forceFill([
                    'sync_status' => 'failed',
                    'sync_error' => Str::limit($message, 500, ''),
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type === 'maintenance_history' && $job->local_id !== null && Schema::hasTable('maintenance_histories')) {
            $history = MaintenanceHistory::query()->find($job->local_id);
            if ($history !== null) {
                $history->forceFill([
                    'sync_status' => 'failed',
                    'sync_error' => Str::limit($message, 500, ''),
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type === 'fleet_zone' && $job->local_id !== null && Schema::hasTable('fleet_zones')) {
            $zone = FleetZone::query()->find($job->local_id);
            if ($zone !== null) {
                $zone->forceFill([
                    'sync_status' => 'failed',
                    'sync_error' => Str::limit($message, 500, ''),
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type !== 'manual_driver' || $job->local_id === null || ! Schema::hasTable('manual_drivers')) {
            return;
        }

        $driver = ManualDriver::query()->find($job->local_id);
        if ($driver === null) {
            return;
        }

        $meta = is_array($driver->meta) ? $driver->meta : [];
        $driver->forceFill([
            'sync_status' => 'failed',
            'sync_error' => Str::limit($message, 500, ''),
            'meta' => [
                ...$meta,
                'syncStatus' => 'failed',
                'syncAction' => $job->action,
                'syncError' => Str::limit($message, 500, ''),
            ],
        ])->saveQuietly();
    }

    private function markLocalRejected(GeotabWriteJob $job, string $reason): void
    {
        $reason = Str::limit($reason, 500, '');
        if ($job->local_type === 'grouped_writeback') {
            foreach ($this->groupedOperations($job) as $operation) {
                $this->markGroupedOperationRejected($operation, $reason);
            }

            return;
        }

        if ($job->local_type === 'manual_vehicle' && $job->local_id !== null && Schema::hasTable('manual_vehicles')) {
            $vehicle = ManualVehicle::query()->find($job->local_id);
            if ($vehicle !== null) {
                $vehicle->forceFill([
                    'sync_status' => 'local_modified',
                    'sync_error' => $reason,
                    'pending_write_job_id' => null,
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type === 'fleet_route' && $job->local_id !== null && Schema::hasTable('fleet_routes')) {
            $route = FleetRoute::query()->find($job->local_id);
            if ($route !== null) {
                $route->forceFill([
                    'sync_status' => 'local_modified',
                    'sync_error' => $reason,
                    'pending_write_job_id' => null,
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type === 'maintenance_history' && $job->local_id !== null && Schema::hasTable('maintenance_histories')) {
            $history = MaintenanceHistory::query()->find($job->local_id);
            if ($history !== null) {
                $history->forceFill([
                    'sync_status' => 'local_modified',
                    'sync_error' => $reason,
                    'pending_write_job_id' => null,
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type === 'fleet_zone' && $job->local_id !== null && Schema::hasTable('fleet_zones')) {
            $zone = FleetZone::query()->find($job->local_id);
            if ($zone !== null) {
                $zone->forceFill([
                    'sync_status' => 'local_modified',
                    'sync_error' => $reason,
                    'pending_write_job_id' => null,
                ])->saveQuietly();
            }

            return;
        }

        if ($job->local_type !== 'manual_driver' || $job->local_id === null || ! Schema::hasTable('manual_drivers')) {
            return;
        }

        $driver = ManualDriver::query()->find($job->local_id);
        if ($driver === null) {
            return;
        }

        $meta = is_array($driver->meta) ? $driver->meta : [];
        $driver->forceFill([
            'sync_status' => 'local_modified',
            'sync_error' => $reason,
            'pending_write_job_id' => null,
            'meta' => [
                ...$meta,
                'syncStatus' => 'local_modified',
                'syncAction' => $job->action,
                'syncError' => $reason,
                'pendingWriteJobId' => null,
            ],
        ])->saveQuietly();
    }

    private function clearDeletedJobLocalState(GeotabWriteJob $job): void
    {
        if ($job->local_type === 'grouped_writeback') {
            foreach ($this->groupedOperations($job) as $operation) {
                $this->clearLocalPendingReference(
                    (string) ($operation['localType'] ?? ''),
                    (string) ($operation['localId'] ?? ''),
                    (string) $job->id,
                    (string) ($operation['action'] ?? $job->action),
                );
            }

            return;
        }

        $this->clearLocalPendingReference(
            (string) ($job->local_type ?? ''),
            (string) ($job->local_id ?? ''),
            (string) $job->id,
            (string) $job->action,
        );
    }

    private function clearLocalPendingReference(string $localType, string $localId, string $jobId, string $action): void
    {
        if ($localId === '') {
            return;
        }

        if ($localType === 'manual_vehicle' && Schema::hasTable('manual_vehicles')) {
            ManualVehicle::query()
                ->whereKey($localId)
                ->where('pending_write_job_id', $jobId)
                ->update([
                    'sync_status' => 'local_modified',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                ]);

            return;
        }

        if ($localType === 'fleet_route' && Schema::hasTable('fleet_routes')) {
            FleetRoute::query()
                ->whereKey($localId)
                ->where('pending_write_job_id', $jobId)
                ->update([
                    'sync_status' => 'local_modified',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                ]);

            return;
        }

        if ($localType === 'maintenance_history' && Schema::hasTable('maintenance_histories')) {
            MaintenanceHistory::query()
                ->whereKey($localId)
                ->where('pending_write_job_id', $jobId)
                ->update([
                    'sync_status' => 'local_modified',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                ]);

            return;
        }

        if ($localType === 'fleet_zone' && Schema::hasTable('fleet_zones')) {
            FleetZone::query()
                ->whereKey($localId)
                ->where('pending_write_job_id', $jobId)
                ->update([
                    'sync_status' => 'local_modified',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                ]);

            return;
        }

        if ($localType !== 'manual_driver' || ! Schema::hasTable('manual_drivers')) {
            return;
        }

        $driver = ManualDriver::query()
            ->whereKey($localId)
            ->where('pending_write_job_id', $jobId)
            ->first();
        if ($driver === null) {
            return;
        }

        $meta = is_array($driver->meta) ? $driver->meta : [];
        $driver->forceFill([
            'sync_status' => 'local_modified',
            'sync_error' => null,
            'pending_write_job_id' => null,
            'meta' => [
                ...$meta,
                'syncStatus' => 'local_modified',
                'syncAction' => $action,
                'syncError' => null,
                'pendingWriteJobId' => null,
            ],
        ])->saveQuietly();
    }

    private function groupedOperations(GeotabWriteJob $job): array
    {
        return collect((array) data_get($job->payload, 'operations', []))
            ->filter(fn ($operation): bool => is_array($operation))
            ->map(fn (array $operation): array => $operation)
            ->values()
            ->all();
    }

    private function markGroupedOperationSynced(array $operation, array $result): void
    {
        $localType = (string) ($operation['localType'] ?? '');
        $localId = (string) ($operation['localId'] ?? '');
        $payload = is_array($operation['payload'] ?? null) ? $operation['payload'] : [];
        $localSnapshotPayload = is_array($result['resolvedLocalSnapshotPayload'] ?? null)
            ? (array) $result['resolvedLocalSnapshotPayload']
            : (is_array($operation['localSnapshotPayload'] ?? null)
            ? $operation['localSnapshotPayload']
            : $payload);

        if ($localType === 'fleet_route_stop' && $localId !== '' && Schema::hasTable('fleet_route_stops')) {
            $stop = FleetRouteStop::query()->find($localId);
            if ($stop !== null) {
                $stop->forceFill([
                    'geotab_zone_id' => (string) ($result['geotabId'] ?? $stop->geotab_zone_id ?? ''),
                    'meta' => [
                        ...(is_array($stop->meta) ? $stop->meta : []),
                        'syncAction' => (string) ($operation['action'] ?? ''),
                        'syncedAt' => now()->toIso8601String(),
                    ],
                ])->saveQuietly();
            }

            return;
        }

        if ($localType === 'manual_vehicle' && $localId !== '' && Schema::hasTable('manual_vehicles')) {
            $vehicle = ManualVehicle::query()->find($localId);
            if ($vehicle !== null) {
                $vehicle->forceFill([
                    'geotab_device_id' => (string) ($result['geotabId'] ?? $vehicle->geotab_device_id ?? ''),
                    'sync_status' => 'synced',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                    'geotab_snapshot' => $payload,
                    'meta' => [
                        ...(is_array($vehicle->meta) ? $vehicle->meta : []),
                        'syncAction' => (string) ($operation['action'] ?? ''),
                        'syncedAt' => now()->toIso8601String(),
                    ],
                ])->saveQuietly();
            }

            return;
        }

        if ($localType === 'fleet_route' && $localId !== '' && Schema::hasTable('fleet_routes')) {
            $route = FleetRoute::query()->find($localId);
            if ($route !== null) {
                $snapshotPayload = $localSnapshotPayload;
                $routeId = (string) ($result['geotabId'] ?? $route->geotab_route_id ?? '');
                if ($routeId !== '' && is_array($snapshotPayload['route'] ?? null)) {
                    $snapshotPayload['route']['id'] = $routeId;
                }
                $route->forceFill([
                    'geotab_route_id' => $routeId,
                    'sync_status' => 'synced',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                    'geotab_snapshot' => $snapshotPayload,
                    'meta' => [
                        ...(is_array($route->meta) ? $route->meta : []),
                        'syncAction' => (string) ($operation['action'] ?? ''),
                        'syncedAt' => now()->toIso8601String(),
                    ],
                ])->saveQuietly();
            }

            return;
        }

        if ($localType === 'fleet_zone' && $localId !== '' && Schema::hasTable('fleet_zones')) {
            $zone = FleetZone::query()->find($localId);
            if ($zone !== null) {
                if (is_array($result['zone'] ?? null)) {
                    $localSnapshotPayload['zone'] = $result['zone'];
                } elseif ((string) ($result['geotabId'] ?? '') !== '' && is_array($localSnapshotPayload['zone'] ?? null)) {
                    $localSnapshotPayload['zone']['id'] = (string) $result['geotabId'];
                }
                $zone->forceFill([
                    'geotab_zone_id' => (string) ($result['geotabId'] ?? $zone->geotab_zone_id ?? ''),
                    'sync_status' => 'synced',
                    'sync_error' => null,
                    'pending_write_job_id' => null,
                    'geotab_snapshot' => $localSnapshotPayload,
                    'meta' => [
                        ...(is_array($zone->meta) ? $zone->meta : []),
                        'syncAction' => (string) ($operation['action'] ?? ''),
                        'syncedAt' => now()->toIso8601String(),
                    ],
                ])->saveQuietly();
            }

            return;
        }

        if ($localType !== 'manual_driver' || $localId === '' || ! Schema::hasTable('manual_drivers')) {
            return;
        }

        $driver = ManualDriver::query()->find($localId);
        if ($driver === null) {
            return;
        }

        $meta = is_array($driver->meta) ? $driver->meta : [];
        $driver->forceFill([
            'sync_status' => 'synced',
            'sync_error' => null,
            'pending_write_job_id' => null,
            'geotab_snapshot' => $payload,
            'meta' => [
                ...$meta,
                'syncStatus' => 'synced',
                'syncAction' => (string) ($operation['action'] ?? ''),
                'syncError' => null,
                'pendingWriteJobId' => null,
                'geotabSnapshot' => $payload,
                'geotabUserId' => (string) ($result['geotabId'] ?? data_get($meta, 'geotabUserId', '')),
                'syncedAt' => now()->toIso8601String(),
            ],
        ])->saveQuietly();
    }

    private function markGroupedOperationFailed(array $operation, string $message): void
    {
        $localType = (string) ($operation['localType'] ?? '');
        $localId = (string) ($operation['localId'] ?? '');
        $message = Str::limit($message, 500, '');

        if ($localType === 'manual_vehicle' && $localId !== '' && Schema::hasTable('manual_vehicles')) {
            ManualVehicle::query()->whereKey($localId)->update([
                'sync_status' => 'failed',
                'sync_error' => $message,
            ]);

            return;
        }

        if ($localType === 'fleet_route' && $localId !== '' && Schema::hasTable('fleet_routes')) {
            FleetRoute::query()->whereKey($localId)->update([
                'sync_status' => 'failed',
                'sync_error' => $message,
            ]);

            return;
        }

        if ($localType === 'fleet_zone' && $localId !== '' && Schema::hasTable('fleet_zones')) {
            FleetZone::query()->whereKey($localId)->update([
                'sync_status' => 'failed',
                'sync_error' => $message,
            ]);

            return;
        }

        if ($localType !== 'manual_driver' || $localId === '' || ! Schema::hasTable('manual_drivers')) {
            return;
        }

        $driver = ManualDriver::query()->find($localId);
        if ($driver === null) {
            return;
        }

        $meta = is_array($driver->meta) ? $driver->meta : [];
        $driver->forceFill([
            'sync_status' => 'failed',
            'sync_error' => $message,
            'meta' => [
                ...$meta,
                'syncStatus' => 'failed',
                'syncAction' => (string) ($operation['action'] ?? ''),
                'syncError' => $message,
            ],
        ])->saveQuietly();
    }

    private function markGroupedOperationRejected(array $operation, string $reason): void
    {
        $localType = (string) ($operation['localType'] ?? '');
        $localId = (string) ($operation['localId'] ?? '');

        if ($localType === 'manual_vehicle' && $localId !== '' && Schema::hasTable('manual_vehicles')) {
            ManualVehicle::query()->whereKey($localId)->update([
                'sync_status' => 'local_modified',
                'sync_error' => $reason,
                'pending_write_job_id' => null,
            ]);

            return;
        }

        if ($localType === 'fleet_route' && $localId !== '' && Schema::hasTable('fleet_routes')) {
            FleetRoute::query()->whereKey($localId)->update([
                'sync_status' => 'local_modified',
                'sync_error' => $reason,
                'pending_write_job_id' => null,
            ]);

            return;
        }

        if ($localType === 'fleet_zone' && $localId !== '' && Schema::hasTable('fleet_zones')) {
            FleetZone::query()->whereKey($localId)->update([
                'sync_status' => 'local_modified',
                'sync_error' => $reason,
                'pending_write_job_id' => null,
            ]);

            return;
        }

        if ($localType !== 'manual_driver' || $localId === '' || ! Schema::hasTable('manual_drivers')) {
            return;
        }

        $driver = ManualDriver::query()->find($localId);
        if ($driver === null) {
            return;
        }

        $meta = is_array($driver->meta) ? $driver->meta : [];
        $driver->forceFill([
            'sync_status' => 'local_modified',
            'sync_error' => $reason,
            'pending_write_job_id' => null,
            'meta' => [
                ...$meta,
                'syncStatus' => 'local_modified',
                'syncAction' => (string) ($operation['action'] ?? ''),
                'syncError' => $reason,
                'pendingWriteJobId' => null,
            ],
        ])->saveQuietly();
    }

    private function queueReviewNotification(GeotabWriteJob $job, string $decision, string $reason = ''): void
    {
        if (! Schema::hasTable('notification_histories')) {
            return;
        }

        $approved = $decision === 'approved';
        $notificationId = 'geotab-writeback-'.$decision.'-'.$job->id.'-'.$job->updated_at?->timestamp;
        $entityName = (string) data_get($job->preview_payload, 'entityName', data_get($job->payload, 'entity.name', data_get($job->payload, 'route.name', $job->entity_type)));
        $message = $approved
            ? 'Your GeoTab push request for '.$entityName.' was approved.'
            : 'Your GeoTab push request for '.$entityName.' was rejected: '.$reason;

        NotificationHistory::query()->create([
            'notification_id' => $notificationId,
            'title' => $approved ? 'GeoTab Push Approved' : 'GeoTab Push Rejected',
            'message' => $message,
            'category' => 'system',
            'status' => 'sent',
            'audience' => 'internal',
            'payload' => [
                'url' => '/settings',
                'icon' => '/icons/Icon-192.png',
                'tag' => $notificationId,
                'jobId' => (string) $job->id,
                'decision' => $decision,
                'createdBy' => $job->created_by,
                'reason' => $reason,
            ],
            'delivered_at' => now(),
        ]);
    }

    private function appendAudit(GeotabWriteJob $job, string $event, string $actor, array $context = []): void
    {
        $trail = is_array($job->audit_trail) ? $job->audit_trail : [];
        $trail[] = $this->auditEvent($event, $actor, $context);
        $job->forceFill(['audit_trail' => $trail])->saveQuietly();
    }

    private function auditEvent(string $event, string $actor, array $context = []): array
    {
        return [
            'event' => $event,
            'actor' => $actor !== '' ? $actor : 'system',
            'timestamp' => now()->toIso8601String(),
            'context' => $context,
        ];
    }

    private function queuePermanentFailureEmail(GeotabWriteJob $job, string $error): void
    {
        $recipients = User::query()
            ->where('role', 'super_administrator')
            ->where('status', 'active')
            ->pluck('email')
            ->filter()
            ->map(fn (mixed $email): string => strtolower(trim((string) $email)))
            ->filter(fn (string $email): bool => filter_var($email, FILTER_VALIDATE_EMAIL) !== false)
            ->values()
            ->all();

        if ($recipients === []) {
            return;
        }

        SendCriticalNotificationEmail::dispatch(
            $recipients,
            '[PioneerPath] GeoTab write-back permanently failed',
            'A GeoTab write-back job permanently failed and requires administrator review.'."\n\n".
            'Job ID: '.$job->id."\n".
            'Action: '.$job->action."\n".
            'Entity: '.$job->entity_type."\n".
            'Error: '.Str::limit($error, 1000, ''),
            ['jobId' => $job->id, 'action' => $job->action, 'entityType' => $job->entity_type],
        );
    }

    private function publishWriteBackStatus(GeotabWriteJob $job): void
    {
        try {
            app(RealtimeFleetEventBroadcaster::class)->publishWriteBackJob($job);
        } catch (\Throwable $e) {
            Log::channel('write_back')->warning('pioneerpath.writeback.realtime_publish_failed', [
                'jobId' => $job->id,
                'status' => $job->status,
                'error' => Str::limit($e->getMessage(), 500, ''),
            ]);
        }
    }
}
