<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Jobs\QueueHealthProbeJob;
use App\Jobs\SendCriticalNotificationEmail;
use App\Models\BillingInvoiceReference;
use App\Models\ClientVehicleAssignment;
use App\Models\FleetClient;
use App\Models\FleetRoute;
use App\Models\FleetRouteStop;
use App\Models\FleetTrip;
use App\Models\FleetZone;
use App\Models\FuelEvent;
use App\Models\GeotabFeedCheckpoint;
use App\Models\GeotabFeedRow;
use App\Models\GeotabWriteJob;
use App\Models\GpsLog;
use App\Models\LoginAttemptLog;
use App\Models\MaintenanceHistory;
use App\Models\MaintenanceWorkOrder;
use App\Models\ManualDriver;
use App\Models\ManualVehicle;
use App\Models\NotificationHistory;
use App\Models\NotificationPreference;
use App\Models\ProofOfDelivery;
use App\Models\PushSubscription;
use App\Models\SystemSetting;
use App\Models\User;
use App\Services\GeotabEntityTypeMismatchException;
use App\Services\GeotabFeedHarvester;
use App\Services\GeotabService;
use App\Services\GeotabWriteBackService;
use App\Services\GoogleMapsEnrichmentService;
use App\Services\JwtAuthService;
use App\Services\ProductionErrorReporter;
use App\Services\PushSenderService;
use App\Services\RealtimeFleetEventBroadcaster;
use App\Services\TripBillingCalculator;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;
use Symfony\Component\HttpFoundation\StreamedResponse;

class GeotabController extends Controller
{
    private ?array $clientThresholdsByName = null;

    private bool $geotabAvailable = true;

    private ?string $geotabUnavailableReason = null;

    private const SNAPSHOT_FRESH_KEY = 'geotab_fleet_snapshot_v4_fresh';

    private const SNAPSHOT_STALE_KEY = 'geotab_fleet_snapshot_v4_stale';

    private const SNAPSHOT_LOCK_KEY = 'geotab_fleet_snapshot_v4_lock';

    private const LIVE_FRESH_KEY = 'geotab_live_snapshot_v2_fresh';

    private const LIVE_STALE_KEY = 'geotab_live_snapshot_v2_stale';

    private const LIVE_LOCK_KEY = 'geotab_live_snapshot_v2_lock';

    private const LIVE_FEED_STATE_KEY = 'geotab_live_snapshot_v2_state';

    private const ANALYTICS_SUMMARY_KEY = 'geotab_summary_analytics_v1';

    private const MAINTENANCE_SUMMARY_KEY = 'geotab_summary_maintenance_v1';

    private const DASHBOARD_SUMMARY_KEY = 'geotab_dashboard_summary_v1';

    private const MAINTENANCE_PREDICTIONS_KEY = 'geotab_predictive_maintenance_v1';

    private const DRIVER_PERFORMANCE_KEY = 'geotab_predictive_driver_performance_v1';

    private const VEHICLE_HEALTH_KEY = 'geotab_predictive_vehicle_health_v1';

    private const ROUTE_EFFICIENCY_KEY = 'geotab_predictive_route_efficiency_v1';

    private const TRIP_FORECAST_KEY = 'geotab_predictive_trip_forecast_v1';

    private const FUEL_TREND_KEY = 'geotab_predictive_fuel_trend_v1';

    private const WARMUP_STATUS_KEY = 'geotab_warmup_status_v1';

    private const MANAGED_USER_ROLES = [
        'super_administrator' => 'Super Administrator',
        'system_administrator' => 'System Administrator',
        'fleet_manager' => 'Fleet Manager',
        'dispatcher' => 'Dispatcher',
        'driver' => 'Driver',
        'accounting_staff' => 'Accounting Staff',
    ];

    private const SYSTEM_ADMIN_CREATABLE_ROLES = [
        'fleet_manager',
        'dispatcher',
        'driver',
        'accounting_staff',
    ];

    public function __construct(
        private readonly GeotabService $geotab,
        private readonly GeotabFeedHarvester $feedHarvester,
        private readonly PushSenderService $pushSender,
        private readonly GeotabWriteBackService $writeBack,
        private readonly RealtimeFleetEventBroadcaster $realtime,
        private readonly GoogleMapsEnrichmentService $googleMaps,
        private readonly TripBillingCalculator $tripBillingCalculator,
    ) {
        if ($this->shouldServeCachedSnapshotOnly()) {
            @set_time_limit(20);
        }
    }

    public function vehicles(): JsonResponse
    {
        return $this->respondData($this->snapshot()['vehicles']);
    }

    public function manualVehicles(Request $request): JsonResponse
    {
        return $this->respondData($this->loadManualVehicles($request->query('status')));
    }

    public function manualVehicle(string $vehicleId): JsonResponse
    {
        $vehicle = $this->findManualVehicle($vehicleId);
        if ($vehicle === null) {
            return $this->respondError('Vehicle not found.', 404);
        }

        $snapshot = $this->snapshot();

        return $this->respondData($this->formatManualVehicle($vehicle, [
            'trips' => is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [],
            'fuel' => is_array(data_get($snapshot, 'fuel.transactions')) ? data_get($snapshot, 'fuel.transactions') : [],
        ]));
    }

    public function storeManualVehicle(Request $request): JsonResponse
    {
        if (! $this->manualVehiclesTableAvailable()) {
            return $this->respondError('Manual vehicles table is not available. Run migrations first.', 503);
        }

        $validated = $this->validateManualVehiclePayload($request);
        $vehicle = ManualVehicle::query()->create($this->manualVehicleAttributes($validated));

        $this->markManualVehicleGeotabDirty($vehicle);
        $this->maybeStoreVehicleExpiryNotification($vehicle, 'created');
        $this->clearFleetCaches();

        return $this->respondData($this->formatManualVehicle($vehicle->refresh()));
    }

    public function updateManualVehicle(Request $request, string $vehicleId): JsonResponse
    {
        if (! $this->manualVehiclesTableAvailable()) {
            return $this->respondError('Manual vehicles table is not available. Run migrations first.', 503);
        }

        $vehicle = $this->findManualVehicle($vehicleId);
        if ($vehicle === null) {
            return $this->respondError('Vehicle not found.', 404);
        }
        if ($this->manualVehicleHasActiveTrip($vehicle) && $this->requestChangesVehicleToInactive($request)) {
            return $this->respondError('Vehicles with active trips cannot be deactivated.', 423);
        }

        $previousDeviceId = trim((string) $vehicle->geotab_device_id);
        $previousRegistration = $vehicle->registration_expiry_date?->toDateString();
        $previousInsurance = $vehicle->insurance_expiry_date?->toDateString();
        $validated = $this->validateManualVehiclePayload($request, partial: true, vehicle: $vehicle);
        $vehicle->fill($this->manualVehicleAttributes($validated, $vehicle));
        $vehicle->save();

        $this->markManualVehicleGeotabDirty($vehicle);

        $registrationChanged = $previousRegistration !== $vehicle->registration_expiry_date?->toDateString();
        $insuranceChanged = $previousInsurance !== $vehicle->insurance_expiry_date?->toDateString();
        if ($registrationChanged || $insuranceChanged) {
            $this->maybeStoreVehicleExpiryNotification($vehicle, 'updated');
        }

        $this->clearFleetCaches();

        return $this->respondData($this->formatManualVehicle($vehicle->refresh()));
    }

    public function deactivateManualVehicle(Request $request, string $vehicleId): JsonResponse
    {
        if (! $this->manualVehiclesTableAvailable()) {
            return $this->respondError('Manual vehicles table is not available. Run migrations first.', 503);
        }

        $vehicle = $this->findManualVehicle($vehicleId);
        if ($vehicle === null) {
            return $this->respondError('Vehicle not found.', 404);
        }
        if ($this->manualVehicleHasActiveTrip($vehicle)) {
            return $this->respondError('Vehicles with active trips cannot be deactivated.', 423);
        }

        $validated = $request->validate([
            'reason' => ['nullable', 'string', 'max:1000'],
        ]);
        $meta = is_array($vehicle->meta) ? $vehicle->meta : [];
        $vehicle->forceFill([
            'status' => 'inactive',
            'deactivated_at' => now(),
            'meta' => [
                ...$meta,
                'deactivationReason' => $this->sanitizeText($validated['reason'] ?? '', ''),
                'deactivatedAt' => now()->toIso8601String(),
            ],
        ])->save();
        $this->clearFleetCaches();

        return $this->respondData($this->formatManualVehicle($vehicle->refresh()));
    }

    public function deleteManualVehicle(string $vehicleId): JsonResponse
    {
        if (! $this->manualVehiclesTableAvailable()) {
            return $this->respondError('Manual vehicles table is not available. Run migrations first.', 503);
        }

        $vehicle = $this->findManualVehicle($vehicleId);
        if ($vehicle === null) {
            return $this->respondError('Vehicle not found.', 404);
        }
        if ($this->manualVehicleHasTripHistory($vehicle)) {
            return $this->respondError(
                'This vehicle has trip history and cannot be deleted. Use Deactivate instead to preserve records.',
                409
            );
        }
        if (Schema::hasTable('geotab_write_jobs')
            && GeotabWriteJob::query()
                ->where('local_type', 'manual_vehicle')
                ->where('local_id', (string) $vehicle->id)
                ->exists()) {
            return $this->respondError(
                'This vehicle has GeoTab sync history and cannot be deleted. Use Deactivate instead to preserve records.',
                409
            );
        }

        $plate = (string) $vehicle->plate_number;
        $id = (string) $vehicle->id;
        $vehicle->delete();
        $this->clearFleetCaches();
        $this->storeCustomNotification(
            'vehicle',
            'Manual Vehicle Deleted',
            $plate.' was removed from PioneerPath manual vehicle records.',
            ['vehicleId' => $id, 'url' => '/vehicles'],
        );

        return $this->respondData([
            'id' => $id,
            'deleted' => true,
        ]);
    }

    public function clients(Request $request): JsonResponse
    {
        if (! $this->fleetClientsTableAvailable()) {
            return $this->respondData([]);
        }

        $query = FleetClient::query()->orderBy('company_name');
        $search = $this->sanitizeText($request->query('search', ''), '');
        if ($search !== '') {
            $query->where(function ($builder) use ($search): void {
                $builder->where('company_name', 'like', '%'.$search.'%')
                    ->orWhere('contact_person_name', 'like', '%'.$search.'%')
                    ->orWhere('erp_customer_id', 'like', '%'.$search.'%');
            });
        }

        $status = strtolower(trim((string) $request->query('status', 'all')));
        if ($status !== '' && $status !== 'all') {
            $query->where('status', $this->normalizeFleetClientStatus($status));
        }

        $snapshot = $this->snapshot();
        $context = [
            'trips' => is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [],
            'billings' => is_array($snapshot['billings'] ?? null) ? $snapshot['billings'] : [],
            'soa' => is_array($snapshot['soa'] ?? null) ? $snapshot['soa'] : [],
        ];

        return $this->respondData(
            $query->get()
                ->map(fn (FleetClient $client): array => $this->formatFleetClient($client, $context))
                ->values()
                ->all()
        );
    }

    public function client(string $clientId): JsonResponse
    {
        $client = $this->findFleetClient($clientId);
        if ($client === null) {
            return $this->respondError('Client not found.', 404);
        }

        return $this->respondData($this->formatFleetClient($client, $this->clientContextFromSnapshot()));
    }

    public function storeClient(Request $request): JsonResponse
    {
        if (! $this->fleetClientsTableAvailable()) {
            return $this->respondError('Clients table is not available. Run migrations first.', 503);
        }

        $validated = $this->validateFleetClientPayload($request);
        $client = FleetClient::query()->create($this->fleetClientAttributes($validated));
        $this->clearFleetCaches();

        return $this->respondData($this->formatFleetClient($client->refresh(), $this->clientContextFromSnapshot()));
    }

    public function updateClient(Request $request, string $clientId): JsonResponse
    {
        if (! $this->fleetClientsTableAvailable()) {
            return $this->respondError('Clients table is not available. Run migrations first.', 503);
        }

        $client = $this->findFleetClient($clientId);
        if ($client === null) {
            return $this->respondError('Client not found.', 404);
        }

        $previousName = (string) $client->company_name;
        $previousBillingAddress = (string) $client->billing_address;
        $validated = $this->validateFleetClientPayload($request, partial: true, client: $client);
        $client->fill($this->fleetClientAttributes($validated, $client));

        if (array_key_exists('companyName', $validated) && (string) $client->company_name !== $previousName) {
            $this->appendFleetClientAudit($client, 'company_name_changed', [
                'from' => $previousName,
                'to' => (string) $client->company_name,
            ], $request);
        }
        if (array_key_exists('billingAddress', $validated) && (string) $client->billing_address !== $previousBillingAddress) {
            $this->appendFleetClientAudit($client, 'billing_address_changed', [
                'from' => $previousBillingAddress,
                'to' => (string) $client->billing_address,
            ], $request);
        }

        $client->save();
        $this->clearFleetCaches();

        return $this->respondData($this->formatFleetClient($client->refresh(), $this->clientContextFromSnapshot()));
    }

    public function deactivateClient(Request $request, string $clientId): JsonResponse
    {
        if (! $this->fleetClientsTableAvailable()) {
            return $this->respondError('Clients table is not available. Run migrations first.', 503);
        }

        $client = $this->findFleetClient($clientId);
        if ($client === null) {
            return $this->respondError('Client not found.', 404);
        }

        $validated = $request->validate([
            'reason' => ['nullable', 'string', 'max:1000'],
        ]);
        $client->forceFill([
            'status' => 'inactive',
            'deactivated_at' => now(),
        ]);
        $this->appendFleetClientAudit($client, 'client_deactivated', [
            'reason' => $this->sanitizeText($validated['reason'] ?? '', ''),
            'hasHistory' => $this->fleetClientHasHistory($client),
        ], $request);
        $client->save();
        $this->clearFleetCaches();

        return $this->respondData($this->formatFleetClient($client->refresh(), $this->clientContextFromSnapshot()));
    }

    public function locations(Request $request): JsonResponse
    {
        if (! $this->canAccessFleetLocationHistory($request)) {
            return $this->respondError('Your role is not allowed to access vehicle location data.', 403);
        }

        $vehicles = $this->snapshot()['vehicles'];

        $locations = array_values(array_filter(array_map(function (array $vehicle): ?array {
            $latitude = (float) ($vehicle['latitude'] ?? 0);
            $longitude = (float) ($vehicle['longitude'] ?? 0);

            if ($latitude === 0.0 && $longitude === 0.0) {
                return null;
            }

            return [
                'geotabId' => $vehicle['geotabId'],
                'latitude' => $latitude,
                'longitude' => $longitude,
                'speed' => (int) ($vehicle['speed'] ?? 0),
                'bearing' => (int) ($vehicle['bearing'] ?? 0),
                'isDriving' => $vehicle['isDriving'] ?? false,
                'lastUpdated' => $vehicle['lastUpdated'],
                'currentZone' => $vehicle['currentZone'] ?? null,
                'destinationZone' => $vehicle['destinationZone'] ?? null,
                'arrivalState' => $vehicle['arrivalState'] ?? null,
                'currentLocationLabel' => $vehicle['currentLocationLabel'] ?? null,
            ];
        }, $vehicles)));

        return $this->respondData($locations);
    }

    public function live(): JsonResponse
    {
        $timing = $this->startEndpointTiming('/fleet/live');

        try {
            $response = $this->respondData($this->liveSnapshot());
            $this->finishEndpointTiming($timing, 'success', [
                'httpStatus' => 200,
            ]);

            return $response;
        } catch (\Throwable $e) {
            $this->finishEndpointTiming($timing, 'exception', [
                'httpStatus' => 500,
                'errorType' => get_class($e),
                'errorMessage' => $e->getMessage(),
            ]);

            throw $e;
        }
    }

    public function stream(Request $request): StreamedResponse
    {
        $channels = collect(explode(',', (string) $request->query('channels', 'live,notification,writeback')))
            ->map(fn (string $channel): string => trim($channel))
            ->filter(fn (string $channel): bool => in_array($channel, ['live', 'notification', 'writeback'], true))
            ->values()
            ->all();
        if ($channels === []) {
            $channels = ['live', 'notification', 'writeback'];
        }

        $sseEnabled = (bool) config('pioneer.sse_enabled', true);
        $devServerOneShot = PHP_SAPI === 'cli-server' && ! $request->boolean('allowLongStream');
        $once = ! $sseEnabled || $request->boolean('once') || $devServerOneShot;
        $maxSeconds = $once ? 1 : max(15, min(300, (int) $request->query('maxSeconds', 240)));
        $clientId = (string) Str::uuid();
        $userKey = 'user:'.($request->attributes->get('auth_user_id') ?: $request->ip());

        return response()->stream(function () use ($channels, $once, $maxSeconds, $clientId, $userKey): void {
            @set_time_limit(0);
            $startedAt = time();
            $lastIds = [];
            $lastHeartbeatAt = 0;

            $this->realtime->registerSseClient($clientId, [
                'channels' => $channels,
                'userKey' => $userKey,
                'connectedAt' => now()->toIso8601String(),
            ]);

            try {
                $this->emitSseEvent($this->realtime->heartbeatEvent());

                do {
                    foreach ($channels as $channel) {
                        foreach ($this->realtime->recentEvents($channel) as $event) {
                            $id = (string) ($event['id'] ?? '');
                            if ($id !== '' && isset($lastIds[$id])) {
                                continue;
                            }

                            $lastIds[$id] = true;
                            $this->emitSseEvent($event);
                        }
                    }

                    if ($once) {
                        break;
                    }

                    if (time() - $lastHeartbeatAt >= 15) {
                        $lastHeartbeatAt = time();
                        $this->emitSseEvent($this->realtime->heartbeatEvent());
                    }

                    if (connection_aborted()) {
                        break;
                    }

                    sleep(1);
                } while ((time() - $startedAt) < $maxSeconds);
            } finally {
                $this->realtime->unregisterSseClient($clientId);
            }
        }, 200, [
            'Content-Type' => 'text/event-stream',
            'Cache-Control' => 'no-cache, no-transform',
            'Connection' => 'keep-alive',
            'X-Accel-Buffering' => 'no',
            'X-Pioneer-Sse-Mode' => ! $sseEnabled ? 'disabled' : ($devServerOneShot ? 'oneshot-dev-server' : 'stream'),
        ]);
    }

    public function trail(Request $request, string $geotabId): JsonResponse
    {
        if (! $this->canAccessFleetLocationHistory($request)) {
            return $this->respondError('Your role is not allowed to access vehicle location history.', 403);
        }

        try {
            $logs = $this->geotab->getGpsTrail($geotabId, 100);

            return $this->respondData($this->formatTrailPoints($logs));
        } catch (\Throwable $e) {
            return $this->respondError($e->getMessage(), 500);
        }
    }

    public function summary(): JsonResponse
    {
        $timing = $this->startEndpointTiming('/fleet/summary');

        try {
            $snapshot = $this->snapshot();
            $response = $this->respondData($snapshot);
            $this->finishEndpointTiming($timing, 'success', [
                'httpStatus' => 200,
            ]);

            return $response;
        } catch (\Throwable $e) {
            $this->finishEndpointTiming($timing, 'exception', [
                'httpStatus' => 500,
                'errorType' => get_class($e),
                'errorMessage' => $e->getMessage(),
            ]);

            throw $e;
        }
    }

    public function summaryLive(): JsonResponse
    {
        return $this->respondData($this->liveSnapshot());
    }

    public function summaryAnalytics(): JsonResponse
    {
        return $this->respondData(
            Cache::remember(
                self::ANALYTICS_SUMMARY_KEY,
                now()->addMinutes(20),
                fn (): array => $this->analyticsSummaryPayload(),
            ),
        );
    }

    public function summaryMaintenance(): JsonResponse
    {
        return $this->respondData(
            Cache::remember(
                self::MAINTENANCE_SUMMARY_KEY,
                now()->addMinutes(15),
                fn (): array => $this->maintenanceSummaryPayload(),
            ),
        );
    }

    public function health(): JsonResponse
    {
        $report = $this->systemHealthReport();

        return response()->json($report, $report['healthy'] ? 200 : 503);
    }

    public function geotabHealth(): JsonResponse
    {
        $health = $this->feedHarvester->health();
        $health['writeBack'] = $this->writeBack->health();
        $health['write_back'] = $health['writeBack'];
        $health['sse'] = [
            ...$this->realtime->sseHealth(),
        ];
        $health['sse']['active'] = ($health['sse']['enabled'] ?? false) && ($health['sse']['mode'] ?? '') === 'stream';
        $health['sse']['active_clients'] = $health['sse']['activeClients'] ?? 0;

        return $this->respondData($health);
    }

    public function auditLogs(Request $request): JsonResponse
    {
        if (! in_array($this->authenticatedRoleFromRequest($request), ['super_administrator', 'system_administrator'], true)) {
            return $this->respondError('Only administrators can view audit logs.', 403);
        }

        $validated = $request->validate([
            'from' => ['nullable', 'date'],
            'to' => ['nullable', 'date'],
            'actor' => ['nullable', 'string', 'max:255'],
            'entityType' => ['nullable', 'string', 'max:120'],
            'actionType' => ['nullable', 'string', 'max:120'],
            'page' => ['nullable', 'integer', 'min:1'],
            'perPage' => ['nullable', 'integer', 'min:1', 'max:100'],
        ]);

        $allEntries = collect($this->collectAuditLogEntries());
        $from = isset($validated['from']) ? Carbon::parse($validated['from'])->startOfDay() : null;
        $to = isset($validated['to']) ? Carbon::parse($validated['to'])->endOfDay() : null;
        $actor = strtolower(trim((string) ($validated['actor'] ?? '')));
        $entityType = strtolower(trim((string) ($validated['entityType'] ?? '')));
        $actionType = strtolower(trim((string) ($validated['actionType'] ?? '')));

        $filtered = $allEntries
            ->filter(function (array $entry) use ($from, $to, $actor, $entityType, $actionType): bool {
                $parsed = $this->parseAuditTimestamp($entry['timestamp'] ?? null);
                if ($from !== null && ($parsed === null || $parsed->lt($from))) {
                    return false;
                }
                if ($to !== null && ($parsed === null || $parsed->gt($to))) {
                    return false;
                }
                $actorText = strtolower(
                    (string) ($entry['actorName'] ?? $entry['actor'] ?? '')
                    .' '.(string) ($entry['actorEmail'] ?? '')
                    .' '.(string) ($entry['actorRole'] ?? '')
                    .' '.(string) ($entry['ipAddress'] ?? '')
                );
                if ($actor !== '' && ! str_contains($actorText, $actor)) {
                    return false;
                }
                if ($entityType !== '' && strtolower((string) ($entry['entityType'] ?? '')) !== $entityType) {
                    return false;
                }
                if ($actionType !== '' && strtolower((string) ($entry['actionType'] ?? '')) !== $actionType) {
                    return false;
                }

                return true;
            })
            ->sortByDesc('timestamp')
            ->values();

        $page = max(1, (int) ($validated['page'] ?? 1));
        $perPage = min(100, max(1, (int) ($validated['perPage'] ?? 25)));
        $total = $filtered->count();
        $lastPage = max(1, (int) ceil($total / $perPage));

        return response()->json([
            'success' => true,
            'data' => $filtered->forPage($page, $perPage)->values()->all(),
            'meta' => [
                'pagination' => [
                    'total' => $total,
                    'currentPage' => $page,
                    'lastPage' => $lastPage,
                    'perPage' => $perPage,
                    'nextPage' => $page < $lastPage ? $page + 1 : null,
                    'previousPage' => $page > 1 ? $page - 1 : null,
                ],
                'filters' => [
                    'entityTypes' => $allEntries->pluck('entityType')->unique()->sort()->values()->all(),
                    'actionTypes' => $allEntries->pluck('actionType')->unique()->sort()->values()->all(),
                ],
            ],
        ]);
    }

    public function clientError(Request $request, ProductionErrorReporter $reporter): JsonResponse
    {
        $payload = $reporter->sanitize($request->all());
        Log::channel('app_errors')->warning('pioneerpath.flutter_client_error', [
            'source' => 'flutter',
            'request' => $reporter->requestContext($request),
            'report' => $payload,
            'userId' => $request->attributes->get('auth_user_id'),
        ]);

        return response()->json(['success' => true, 'stored' => true]);
    }

    private function systemHealthReport(): array
    {
        $checks = [
            'database' => $this->databaseHealthCheck(),
            'cache' => $this->cacheHealthCheck(),
            'queue' => $this->queueHealthCheck(),
            'scheduler' => $this->schedulerHealthCheck(),
            'disk' => $this->diskHealthCheck(),
            'php' => $this->phpRuntimeHealthCheck(),
        ];
        $healthy = collect($checks)->every(fn (array $check): bool => ($check['ok'] ?? false) === true);

        return [
            'success' => $healthy,
            'healthy' => $healthy,
            'status' => $healthy ? 'ok' : 'degraded',
            'generatedAt' => now()->toIso8601String(),
            'checks' => $checks,
        ];
    }

    private function databaseHealthCheck(): array
    {
        $table = 'pioneer_health_'.Str::lower(Str::random(12));
        try {
            DB::statement("CREATE TEMPORARY TABLE {$table} (id INTEGER PRIMARY KEY, value VARCHAR(32))");
            DB::table($table)->insert(['id' => 1, 'value' => 'ok']);
            $value = DB::table($table)->where('id', 1)->value('value');
            DB::statement("DROP TABLE {$table}");

            return [
                'ok' => $value === 'ok',
                'connection' => config('database.default'),
                'canWriteAndRead' => $value === 'ok',
            ];
        } catch (\Throwable $e) {
            Log::channel('app_errors')->error('pioneerpath.health.database_failed', [
                'error' => $e->getMessage(),
            ]);

            return [
                'ok' => false,
                'connection' => config('database.default'),
                'canWriteAndRead' => false,
                'error' => 'database_unavailable',
            ];
        }
    }

    private function cacheHealthCheck(): array
    {
        $key = 'pioneer_health_cache_'.Str::uuid();
        try {
            Cache::put($key, 'ok', now()->addMinute());
            $value = Cache::get($key);
            Cache::forget($key);

            return [
                'ok' => $value === 'ok',
                'store' => config('cache.default'),
                'canWriteAndRead' => $value === 'ok',
            ];
        } catch (\Throwable $e) {
            Log::channel('app_errors')->error('pioneerpath.health.cache_failed', [
                'error' => $e->getMessage(),
            ]);

            return [
                'ok' => false,
                'store' => config('cache.default'),
                'canWriteAndRead' => false,
                'error' => 'cache_unavailable',
            ];
        }
    }

    private function queueHealthCheck(): array
    {
        $connection = (string) config('queue.default');
        $probeId = (string) Str::uuid();
        try {
            QueueHealthProbeJob::dispatch($probeId);
        } catch (\Throwable $e) {
            Log::channel('app_errors')->error('pioneerpath.health.queue_dispatch_failed', [
                'error' => $e->getMessage(),
            ]);

            return [
                'ok' => false,
                'connection' => $connection,
                'workerProcessing' => false,
                'error' => 'queue_dispatch_failed',
            ];
        }

        $lastProcessed = Cache::get('pioneer_queue_last_processed_at');
        $processedAt = is_string($lastProcessed) ? Carbon::parse($lastProcessed) : null;
        $fresh = $processedAt !== null && $processedAt->greaterThan(now()->subMinutes(10));
        $ok = $connection === 'sync' || $fresh || app()->environment('local', 'testing');

        return [
            'ok' => $ok,
            'connection' => $connection,
            'workerProcessing' => $connection === 'sync' || $fresh,
            'lastProcessedAt' => $processedAt?->toIso8601String(),
            'lastProcessedAgeSeconds' => $processedAt?->diffInSeconds(now()),
            'probeQueued' => true,
        ];
    }

    private function schedulerHealthCheck(): array
    {
        $lastRuns = [
            'geotab:feed-sync' => Cache::get('geotab_scheduler_last_run_geotab_feed_sync'),
            'geotab:snapshot-warm' => Cache::get('geotab_scheduler_last_run_geotab_snapshot_warm'),
            'geotab:warm-session' => Cache::get('geotab_scheduler_last_run_geotab_warm_session'),
            'geotab:feed-prune' => Cache::get('geotab_scheduler_last_run_geotab_feed_prune'),
            'geotab:writeback-process --limit=10' => Cache::get('geotab_scheduler_last_run_geotab_writeback_process'),
        ];
        $hasAnyRun = collect($lastRuns)->filter()->isNotEmpty();

        return [
            'ok' => $hasAnyRun || app()->environment('local', 'testing'),
            'lastRuns' => $lastRuns,
            'productionCron' => '* * * * * php /path/to/artisan schedule:run >> /dev/null 2>&1',
        ];
    }

    private function diskHealthCheck(): array
    {
        $path = storage_path();
        $free = @disk_free_space($path);
        $total = @disk_total_space($path);
        $freeBytes = is_int($free) || is_float($free) ? (int) $free : null;
        $totalBytes = is_int($total) || is_float($total) ? (int) $total : null;
        $minimumFreeBytes = 512 * 1024 * 1024;

        return [
            'ok' => $freeBytes === null ? false : $freeBytes > $minimumFreeBytes,
            'storagePath' => $path,
            'freeBytes' => $freeBytes,
            'totalBytes' => $totalBytes,
            'minimumFreeBytes' => $minimumFreeBytes,
        ];
    }

    private function phpRuntimeHealthCheck(): array
    {
        return [
            'ok' => true,
            'memoryLimit' => ini_get('memory_limit'),
            'memoryUsageBytes' => memory_get_usage(true),
            'peakMemoryUsageBytes' => memory_get_peak_usage(true),
            'phpVersion' => PHP_VERSION,
        ];
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function collectAuditLogEntries(): array
    {
        $entries = [];
        if (Schema::hasTable('users') && Schema::hasColumn('users', 'activity_log')) {
            User::query()->select(['id', 'name', 'email', 'role', 'activity_log'])->orderByDesc('id')->limit(500)->get()
                ->each(function (User $user) use (&$entries): void {
                    foreach (array_values(is_array($user->activity_log) ? $user->activity_log : []) as $entry) {
                        if (! is_array($entry)) {
                            continue;
                        }
                        if (($entry['action'] ?? '') === 'login') {
                            continue;
                        }
                        $entries[] = $this->normalizeAuditEntry($entry, [
                            'entityType' => 'user',
                            'entityId' => (string) $user->id,
                            'entityLabel' => (string) $user->name,
                            'actorRole' => (string) ($user->role ?? ''),
                            'after' => ['name' => $user->name, 'email' => $user->email, 'role' => $user->role],
                        ]);
                    }
                });
        }

        if (Schema::hasTable('system_settings') && Schema::hasColumn('system_settings', 'audit_log')) {
            SystemSetting::query()->select(['id', 'audit_log'])->get()
                ->each(function (SystemSetting $setting) use (&$entries): void {
                    foreach (array_values(is_array($setting->audit_log) ? $setting->audit_log : []) as $entry) {
                        if (! is_array($entry)) {
                            continue;
                        }
                        $entries[] = $this->normalizeAuditEntry($entry, [
                            'entityType' => 'system_setting',
                            'entityId' => (string) $setting->id,
                            'entityLabel' => 'System Settings',
                        ]);
                    }
                });
        }

        if (Schema::hasTable('fleet_clients') && Schema::hasColumn('fleet_clients', 'audit_trail')) {
            FleetClient::query()->select(['id', 'company_name', 'audit_trail'])->orderByDesc('id')->limit(500)->get()
                ->each(function (FleetClient $client) use (&$entries): void {
                    foreach (array_values(is_array($client->audit_trail) ? $client->audit_trail : []) as $entry) {
                        if (! is_array($entry)) {
                            continue;
                        }
                        $entries[] = $this->normalizeAuditEntry($entry, [
                            'entityType' => 'client',
                            'entityId' => (string) $client->id,
                            'entityLabel' => (string) $client->company_name,
                            'after' => ['companyName' => $client->company_name],
                        ]);
                    }
                });
        }

        if (Schema::hasTable('geotab_write_jobs') && Schema::hasColumn('geotab_write_jobs', 'audit_trail')) {
            GeotabWriteJob::query()->select(['id', 'action', 'entity_type', 'local_id', 'audit_trail'])->orderByDesc('id')->limit(500)->get()
                ->each(function (GeotabWriteJob $job) use (&$entries): void {
                    foreach (array_values(is_array($job->audit_trail) ? $job->audit_trail : []) as $entry) {
                        if (! is_array($entry)) {
                            continue;
                        }
                        $entries[] = $this->normalizeAuditEntry($entry, [
                            'entityType' => 'geotab_write_job',
                            'entityId' => (string) $job->id,
                            'entityLabel' => (string) ($job->entity_type.' '.$job->local_id),
                            'after' => [
                                'action' => $job->action,
                                'entityType' => $job->entity_type,
                                'localId' => $job->local_id,
                            ],
                        ]);
                    }
                });
        }

        if (Schema::hasTable('billing_invoice_references') && Schema::hasColumn('billing_invoice_references', 'status_history')) {
            BillingInvoiceReference::query()->select(['id', 'trip_id', 'status_history'])->orderByDesc('id')->limit(500)->get()
                ->each(function (BillingInvoiceReference $invoice) use (&$entries): void {
                    foreach (array_values(is_array($invoice->status_history) ? $invoice->status_history : []) as $entry) {
                        if (! is_array($entry)) {
                            continue;
                        }
                        $entries[] = $this->normalizeAuditEntry($entry, [
                            'entityType' => 'invoice',
                            'entityId' => (string) ($invoice->trip_id ?: $invoice->id),
                            'entityLabel' => 'Invoice '.$invoice->id,
                        ]);
                    }
                });
        }

        if (Schema::hasTable('login_attempt_logs')) {
            LoginAttemptLog::query()
                ->with('user:id,name,email,role')
                ->orderByDesc('attempted_at')
                ->limit(500)
                ->get()
                ->each(function (LoginAttemptLog $attempt) use (&$entries): void {
                    $user = $attempt->user;
                    $entries[] = $this->normalizeAuditEntry([
                        'action' => $attempt->successful ? 'login' : 'login_failed',
                        'actor' => $attempt->email ?: ($user?->email ?? 'unknown'),
                        'actorName' => $user?->name ?: ($attempt->email ?: 'Unknown user'),
                        'actorEmail' => $attempt->email ?: ($user?->email ?? null),
                        'actorRole' => $user?->role,
                        'timestamp' => $attempt->attempted_at?->toIso8601String(),
                        'ipAddress' => $attempt->ip_address,
                        'failureReason' => $attempt->failure_reason,
                    ], [
                        'entityType' => 'session',
                        'entityId' => (string) $attempt->id,
                        'entityLabel' => $attempt->successful ? 'Successful login' : 'Failed login',
                    ]);
                });
        }

        return $entries;
    }

    /**
     * @param  array<string, mixed>  $entry
     * @param  array<string, mixed>  $fallback
     * @return array<string, mixed>
     */
    private function normalizeAuditEntry(array $entry, array $fallback): array
    {
        $context = $entry['context'] ?? $entry['meta'] ?? $entry['changes'] ?? [];
        $actionType = $this->canonicalAuditAction((string) ($entry['action'] ?? $entry['event'] ?? $fallback['actionType'] ?? 'updated'));
        $before = $entry['before'] ?? (is_array($context) ? ($context['before'] ?? null) : null);
        $after = $entry['after'] ?? (is_array($context) ? ($context['after'] ?? null) : null) ?? ($fallback['after'] ?? null);
        $timestamp = (string) ($entry['timestamp'] ?? $entry['at'] ?? now()->toIso8601String());
        $parsedTimestamp = $this->parseAuditTimestamp($timestamp);

        return [
            'timestamp' => $timestamp,
            'displayTimestamp' => $this->formatAuditTimestamp($parsedTimestamp),
            'actor' => (string) ($entry['actor'] ?? $fallback['actor'] ?? 'system'),
            'actorName' => (string) ($entry['actorName'] ?? $entry['actor'] ?? $fallback['actor'] ?? 'system'),
            'actorEmail' => (string) ($entry['actorEmail'] ?? ''),
            'actorRole' => (string) ($entry['actorRole'] ?? $fallback['actorRole'] ?? ''),
            'actionType' => $actionType,
            'actionLabel' => $this->auditActionLabel($actionType),
            'entityType' => (string) ($entry['entityType'] ?? $fallback['entityType'] ?? 'record'),
            'entityId' => (string) ($entry['entityId'] ?? $fallback['entityId'] ?? ''),
            'entityLabel' => (string) ($entry['entityLabel'] ?? $fallback['entityLabel'] ?? ''),
            'changedFields' => array_values(array_map('strval', (array) ($entry['changedFields'] ?? (is_array($context) ? array_keys($context) : [])))),
            'before' => $this->sanitizeAuditValue($this->normalizeAuditDiffValue($before, $actionType, 'before')),
            'after' => $this->sanitizeAuditValue($this->normalizeAuditDiffValue($after, $actionType, 'after')),
            'ipAddress' => (string) ($entry['ipAddress'] ?? ''),
            'failureReason' => (string) ($entry['failureReason'] ?? ''),
            'isSessionEvent' => in_array($actionType, ['login', 'login_failed'], true),
            'source' => (string) ($fallback['entityType'] ?? 'audit'),
        ];
    }

    private function canonicalAuditAction(string $action): string
    {
        $normalized = Str::of($action)->lower()->replace([' ', '-'], '_')->toString();

        return match ($normalized) {
            'create', 'created' => 'create',
            'update', 'updated', 'company_name_changed', 'billing_address_changed' => 'update',
            'role_changed', 'role_change' => 'role_change',
            'deactivate', 'deactivated', 'client_deactivated' => 'deactivate',
            'password_reset', 'password_reset_link_sent', 'password_reset_completed', 'password_changed' => 'password_reset',
            'login_failed', 'failed_login' => 'login_failed',
            'login' => 'login',
            default => $normalized,
        };
    }

    private function auditActionLabel(string $action): string
    {
        return match ($action) {
            'login' => 'Login',
            'login_failed' => 'Failed Login',
            'create' => 'Create',
            'update' => 'Update',
            'role_change' => 'Role Change',
            'deactivate' => 'Deactivate',
            'password_reset' => 'Password Reset',
            default => Str::of($action)->replace('_', ' ')->title()->toString(),
        };
    }

    private function normalizeAuditDiffValue(mixed $value, string $actionType, string $side): mixed
    {
        if (is_array($value)) {
            if (array_key_exists('from', $value) || array_key_exists('to', $value)) {
                return [
                    'value' => $value[$side === 'before' ? 'from' : 'to'] ?? null,
                ];
            }

            return $value;
        }

        if ($value !== null && $value !== '') {
            $field = match ($actionType) {
                'role_change' => 'role',
                'deactivate' => 'status',
                default => 'value',
            };

            return [$field => $value];
        }

        return null;
    }

    private function formatAuditTimestamp(?Carbon $timestamp): string
    {
        if ($timestamp === null) {
            return '';
        }

        return $timestamp->copy()
            ->timezone('Asia/Manila')
            ->format('F j, Y g:i A');
    }

    private function parseAuditTimestamp(mixed $timestamp): ?Carbon
    {
        if (! is_string($timestamp) || trim($timestamp) === '') {
            return null;
        }

        try {
            return Carbon::parse($timestamp);
        } catch (\Throwable) {
            return null;
        }
    }

    private function sanitizeAuditValue(mixed $value): mixed
    {
        if (is_array($value)) {
            $sanitized = [];
            foreach ($value as $key => $item) {
                $keyString = strtolower((string) $key);
                $sanitized[$key] = str_contains($keyString, 'password') || str_contains($keyString, 'token')
                    ? '[redacted]'
                    : $this->sanitizeAuditValue($item);
            }

            return $sanitized;
        }

        return $value;
    }

    private function healthSessionCacheKey(): string
    {
        return 'geotab_session_'.md5(strtolower(
            (string) config('geotab.database', '')
            .'|'
            .(string) config('geotab.username', '')
            .'|'
            .(string) config('geotab.server', 'my.geotab.com'),
        ));
    }

    public function dashboard(): JsonResponse
    {
        return $this->respondData($this->snapshot()['dashboard']);
    }

    public function dashboardSummary(): JsonResponse
    {
        return $this->respondData(
            Cache::remember(
                self::DASHBOARD_SUMMARY_KEY,
                now()->addSeconds(120),
                fn (): array => $this->dashboardSummaryPayload(),
            ),
        );
    }

    public function maintenancePredictions(): JsonResponse
    {
        return $this->respondData(
            Cache::remember(
                self::MAINTENANCE_PREDICTIONS_KEY,
                now()->addSeconds(3600),
                fn (): array => $this->maintenancePredictionsPayload(),
            ),
        );
    }

    public function driverPerformance(): JsonResponse
    {
        return $this->respondData(
            Cache::remember(
                self::DRIVER_PERFORMANCE_KEY,
                now()->addSeconds(600),
                fn (): array => $this->driverPerformancePayload(),
            ),
        );
    }

    public function vehicleHealth(): JsonResponse
    {
        return $this->respondData(
            Cache::remember(
                self::VEHICLE_HEALTH_KEY,
                now()->addSeconds(600),
                fn (): array => $this->vehicleHealthPayload(),
            ),
        );
    }

    public function routeEfficiency(): JsonResponse
    {
        return $this->respondData(
            Cache::remember(
                self::ROUTE_EFFICIENCY_KEY,
                now()->addSeconds(600),
                fn (): array => $this->routeEfficiencyPayload(),
            ),
        );
    }

    public function tripForecast(): JsonResponse
    {
        return $this->respondData(
            Cache::remember(
                self::TRIP_FORECAST_KEY,
                now()->addSeconds(3600),
                fn (): array => $this->tripForecastPayload(),
            ),
        );
    }

    public function fuelTrend(): JsonResponse
    {
        return $this->respondData(
            Cache::remember(
                self::FUEL_TREND_KEY,
                now()->addSeconds(600),
                fn (): array => $this->fuelTrendPayload(),
            ),
        );
    }

    public function mapsConfig(): JsonResponse
    {
        $browserKey = trim((string) config('services.google_maps.browser_key', ''));

        return $this->respondData([
            'configured' => $browserKey !== '',
            'serverConfigured' => $this->googleMaps->isConfigured(),
            'browserKey' => $browserKey,
            'provider' => 'google_maps',
            'enabledApis' => [
                'maps_javascript_sdk',
                'roads_api',
                'distance_matrix_api',
                'routes_api',
                'geocoding_api',
            ],
        ]);
    }

    public function optimizeDispatchOrder(Request $request): JsonResponse
    {
        $snapshot = $this->snapshot();
        $pendingTrips = is_array($request->input('trips'))
            ? $request->input('trips')
            : array_values(array_filter(
                is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [],
                fn (array $trip): bool => strtolower((string) ($trip['status'] ?? '')) === 'pending',
            ));

        $depot = $this->coordinateParts($request->input('depot'));
        if ($depot === null) {
            $depot = $this->configuredGoogleMapsDepot();
        }

        $stops = [];
        foreach ($pendingTrips as $index => $trip) {
            if (! is_array($trip)) {
                continue;
            }

            $coordinate = $this->coordinateParts(
                $trip['stopPoint']
                    ?? $trip['destinationPoint']
                    ?? data_get($trip, 'destination.coordinate')
                    ?? null,
            );

            if ($coordinate === null) {
                continue;
            }

            $stops[] = [
                'tripId' => (string) ($trip['tripId'] ?? $trip['id'] ?? 'trip-'.$index),
                'customer' => $this->sanitizeText($trip['customer'] ?? '', 'Customer'),
                'destination' => $this->sanitizeText($trip['destination'] ?? '', 'Destination'),
                'currentSequence' => $index + 1,
                'coordinate' => $coordinate,
            ];
        }

        $result = $this->googleMaps->optimizeStopOrder($depot ?? [], $stops);

        return $this->respondData([
            ...$result,
            'depot' => $depot,
            'stopCount' => count($stops),
            'advisoryOnly' => true,
        ]);
    }

    public function drivers(): JsonResponse
    {
        return $this->respondData($this->snapshot()['drivers']);
    }

    public function managedUsers(Request $request): JsonResponse
    {
        if (! $this->managedUsersTableAvailable()) {
            return $this->respondData([]);
        }

        $query = User::query()->orderBy('name');
        $role = trim((string) $request->query('role', 'all'));
        if ($role !== '' && strtolower($role) !== 'all') {
            $query->where('role', $this->normalizeManagedUserRole($role));
        }

        $status = strtolower(trim((string) $request->query('status', 'all')));
        if ($status !== '' && $status !== 'all') {
            $query->where('status', $this->normalizeManagedUserStatus($status));
        }

        return $this->respondData(
            $query->get()
                ->map(fn (User $user): array => $this->formatManagedUser($user))
                ->values()
                ->all()
        );
    }

    public function managedUser(Request $request, string $userId): JsonResponse
    {
        if (! $this->managedUsersTableAvailable()) {
            return $this->respondError('User management table is not available. Run migrations first.', 503);
        }

        $user = User::query()->find($userId);
        if ($user === null) {
            return $this->respondError('User account not found.', 404);
        }

        return $this->respondData($this->formatManagedUser($user, includeActivity: true));
    }

    public function storeManagedUser(Request $request): JsonResponse
    {
        if (! $this->managedUsersTableAvailable()) {
            return $this->respondError('User management table is not available. Run migrations first.', 503);
        }

        $validated = $request->validate([
            'fullName' => ['required', 'string', 'max:255'],
            'email' => ['required', 'email', 'max:255', Rule::unique('users', 'email')],
            'role' => ['required', 'string'],
            'phone' => ['nullable', 'string', 'max:80'],
            'temporaryPassword' => ['required', 'string', 'min:8', 'max:255'],
            'status' => ['nullable', 'string'],
            'actor' => ['nullable', 'string', 'max:255'],
            'actorRole' => ['nullable', 'string'],
        ]);

        $actorRole = $this->actorManagedUserRole($request);
        $targetRole = $this->normalizeManagedUserRole($validated['role']);
        if (! $this->managedUserCanManageRole($actorRole, $targetRole)) {
            return $this->respondError('Your role cannot create or manage that account level.', 403);
        }

        $actor = $this->sanitizeText($validated['actor'] ?? $actorRole, $actorRole);
        $user = User::query()->create([
            'name' => $this->sanitizeText($validated['fullName'], 'User'),
            'email' => strtolower(trim((string) $validated['email'])),
            'password' => Hash::make((string) $validated['temporaryPassword']),
            'role' => $targetRole,
            'phone' => trim((string) ($validated['phone'] ?? '')) ?: null,
            'status' => $this->normalizeManagedUserStatus($validated['status'] ?? 'active'),
            'must_change_password' => true,
            'created_by' => $actor,
            'activity_log' => [
                $this->managedUserActivity('created', $actor, [
                    'after' => [
                        'name' => $this->sanitizeText($validated['fullName'], 'User'),
                        'email' => strtolower(trim((string) $validated['email'])),
                        'role' => $targetRole,
                        'phone' => trim((string) ($validated['phone'] ?? '')) ?: null,
                        'status' => $this->normalizeManagedUserStatus($validated['status'] ?? 'active'),
                    ],
                    'temporaryPasswordIssued' => true,
                ]),
            ],
        ]);

        return $this->respondData([
            ...$this->formatManagedUser($user->refresh(), includeActivity: true),
            'temporaryPassword' => (string) $validated['temporaryPassword'],
            'temporaryPasswordShownOnce' => true,
        ]);
    }

    public function updateManagedUser(Request $request, string $userId): JsonResponse
    {
        if (! $this->managedUsersTableAvailable()) {
            return $this->respondError('User management table is not available. Run migrations first.', 503);
        }

        $user = User::query()->find($userId);
        if ($user === null) {
            return $this->respondError('User account not found.', 404);
        }

        $actorRole = $this->actorManagedUserRole($request);
        $currentRole = $this->normalizeManagedUserRole($user->role ?? 'driver');
        $targetRole = $request->has('role')
            ? $this->normalizeManagedUserRole($request->input('role'))
            : $currentRole;
        if (! $this->managedUserCanManageRole($actorRole, $currentRole) || ! $this->managedUserCanManageRole($actorRole, $targetRole)) {
            return $this->respondError('Your role cannot edit that account level.', 403);
        }

        $validated = $request->validate([
            'fullName' => ['nullable', 'string', 'max:255'],
            'email' => ['nullable', 'email', 'max:255', Rule::unique('users', 'email')->ignore($user->id)],
            'role' => ['nullable', 'string'],
            'phone' => ['nullable', 'string', 'max:80'],
            'status' => ['nullable', 'string'],
            'actor' => ['nullable', 'string', 'max:255'],
            'actorRole' => ['nullable', 'string'],
        ]);

        if ($this->requestWouldDeactivateManagedUser($validated, $user) && $this->managedDriverHasActiveTrip($user)) {
            return $this->respondError('Users assigned to active driver trips cannot be deactivated until those trips complete.', 423);
        }

        $actor = $this->sanitizeText($validated['actor'] ?? $actorRole, $actorRole);
        $activity = is_array($user->activity_log) ? $user->activity_log : [];
        $updates = [];
        $beforeAudit = [];
        $afterAudit = [];

        if (array_key_exists('fullName', $validated)) {
            $next = $this->sanitizeText($validated['fullName'], $user->name);
            if ($next !== (string) $user->name) {
                $beforeAudit['name'] = $user->name;
                $afterAudit['name'] = $next;
            }
            $updates['name'] = $next;
        }
        if (array_key_exists('email', $validated)) {
            $next = strtolower(trim((string) $validated['email']));
            if ($next !== (string) $user->email) {
                $beforeAudit['email'] = $user->email;
                $afterAudit['email'] = $next;
            }
            $updates['email'] = $next;
        }
        if (array_key_exists('phone', $validated)) {
            $next = trim((string) ($validated['phone'] ?? '')) ?: null;
            if ($next !== ($user->phone ?: null)) {
                $beforeAudit['phone'] = $user->phone;
                $afterAudit['phone'] = $next;
            }
            $updates['phone'] = $next;
        }
        if (array_key_exists('role', $validated)) {
            $updates['role'] = $targetRole;
            if ($currentRole !== $targetRole) {
                $beforeAudit['role'] = $currentRole;
                $afterAudit['role'] = $targetRole;
                $activity[] = $this->managedUserActivity('role_changed', $actor, [
                    'before' => $currentRole,
                    'after' => $targetRole,
                ]);
            }
        }
        if (array_key_exists('status', $validated)) {
            $nextStatus = $this->normalizeManagedUserStatus($validated['status']);
            $updates['status'] = $nextStatus;
            $updates['deactivated_at'] = $nextStatus === 'inactive' ? ($user->deactivated_at ?: now()) : null;
            if ($nextStatus !== ($user->status ?: 'active')) {
                $beforeAudit['status'] = $user->status ?: 'active';
                $afterAudit['status'] = $nextStatus;
                $activity[] = $this->managedUserActivity('status_changed', $actor, [
                    'before' => $user->status ?: 'active',
                    'after' => $nextStatus,
                ]);
            }
        }

        if ($updates !== []) {
            $activity[] = $this->managedUserActivity('updated', $actor, [
                'fields' => array_keys($updates),
                'before' => $beforeAudit,
                'after' => $afterAudit,
            ]);
            $updates['activity_log'] = $activity;
            $user->forceFill($updates)->save();
        }

        return $this->respondData($this->formatManagedUser($user->refresh(), includeActivity: true));
    }

    public function resetManagedUserPassword(Request $request, string $userId): JsonResponse
    {
        if (! $this->managedUsersTableAvailable()) {
            return $this->respondError('User management table is not available. Run migrations first.', 503);
        }

        $user = User::query()->find($userId);
        if ($user === null) {
            return $this->respondError('User account not found.', 404);
        }

        $actorRole = $this->actorManagedUserRole($request);
        $targetRole = $this->normalizeManagedUserRole($user->role ?? 'driver');
        if (! $this->managedUserCanManageRole($actorRole, $targetRole)) {
            return $this->respondError('Your role cannot reset that account password.', 403);
        }

        $validated = $request->validate([
            'actor' => ['nullable', 'string', 'max:255'],
            'actorRole' => ['nullable', 'string'],
        ]);
        $actor = $this->sanitizeText($validated['actor'] ?? $actorRole, $actorRole);
        $temporaryPassword = $this->generateTemporaryPassword();
        $activity = is_array($user->activity_log) ? $user->activity_log : [];
        $activity[] = $this->managedUserActivity('password_reset', $actor, [
            'after' => [
                'mustChangePassword' => true,
                'temporaryPasswordIssued' => true,
            ],
            'temporaryPasswordIssued' => true,
        ]);

        $user->forceFill([
            'password' => Hash::make($temporaryPassword),
            'must_change_password' => true,
            'activity_log' => $activity,
        ])->save();

        return $this->respondData([
            ...$this->formatManagedUser($user->refresh(), includeActivity: true),
            'temporaryPassword' => $temporaryPassword,
            'temporaryPasswordShownOnce' => true,
        ]);
    }

    public function deactivateManagedUser(Request $request, string $userId): JsonResponse
    {
        if (! $this->managedUsersTableAvailable()) {
            return $this->respondError('User management table is not available. Run migrations first.', 503);
        }

        $user = User::query()->find($userId);
        if ($user === null) {
            return $this->respondError('User account not found.', 404);
        }

        $actorRole = $this->actorManagedUserRole($request);
        $targetRole = $this->normalizeManagedUserRole($user->role ?? 'driver');
        if (! $this->managedUserCanManageRole($actorRole, $targetRole)) {
            return $this->respondError('Your role cannot deactivate that account level.', 403);
        }
        if ($this->managedDriverHasActiveTrip($user)) {
            return $this->respondError('Users assigned to active driver trips cannot be deactivated until those trips complete.', 423);
        }

        $validated = $request->validate([
            'reason' => ['required', 'string', 'max:1000'],
            'actor' => ['nullable', 'string', 'max:255'],
            'actorRole' => ['nullable', 'string'],
        ]);
        $actor = $this->sanitizeText($validated['actor'] ?? $actorRole, $actorRole);
        $activity = is_array($user->activity_log) ? $user->activity_log : [];
        $activity[] = $this->managedUserActivity('deactivated', $actor, [
            'before' => [
                'status' => $user->status ?: 'active',
            ],
            'after' => [
                'status' => 'inactive',
            ],
            'reason' => $this->sanitizeText($validated['reason'], ''),
        ]);

        $user->forceFill([
            'status' => 'inactive',
            'deactivated_at' => now(),
            'activity_log' => $activity,
        ])->save();

        return $this->respondData($this->formatManagedUser($user->refresh(), includeActivity: true));
    }

    public function deleteManagedUser(Request $request, string $userId): JsonResponse
    {
        if (! $this->managedUsersTableAvailable()) {
            return $this->respondError('User management table is not available. Run migrations first.', 503);
        }

        $user = User::query()->find($userId);
        if ($user === null) {
            return $this->respondError('User account not found.', 404);
        }

        $actorRole = $this->actorManagedUserRole($request);
        $targetRole = $this->normalizeManagedUserRole($user->role ?? 'driver');
        if (! $this->managedUserCanManageRole($actorRole, $targetRole)) {
            return $this->respondError('Your role cannot delete that account level.', 403);
        }

        if ($targetRole === 'super_administrator') {
            $superAdministratorCount = User::query()
                ->where('role', 'super_administrator')
                ->count();

            if ($superAdministratorCount <= 1) {
                return $this->respondError('Cannot delete the only Super Admin.', 423);
            }

            return $this->respondError('Super Administrator accounts cannot be deleted. Use Deactivate instead.', 423);
        }

        if ($this->managedDriverHasActiveTrip($user)) {
            return $this->respondError('This user has active trips and cannot be deleted.', 423);
        }

        if ($this->managedUserHasAuditHistory($user)) {
            return $this->respondError('This user has audit history and cannot be deleted.', 423);
        }

        $deletedUser = $this->formatManagedUser($user);
        $user->delete();

        return $this->respondData([
            ...$deletedUser,
            'deleted' => true,
        ]);
    }

    public function loginManagedUser(Request $request, JwtAuthService $jwtAuth): JsonResponse
    {
        if (! $this->managedUsersTableAvailable()) {
            return $this->respondError('User management table is not available. Run migrations first.', 503);
        }

        $request->merge([
            'username' => $request->input('username', $request->input('email')),
        ]);

        $validated = $request->validate([
            'username' => ['required', 'string', 'max:255'],
            'password' => ['required', 'string', 'max:255'],
            'platform' => ['nullable', 'string', 'max:30'],
        ]);
        $username = strtolower(trim((string) $validated['username']));
        $ip = (string) $request->ip();

        if (Cache::get($this->loginIpLockKey($ip))) {
            $this->recordLoginAttempt($username, null, $ip, false, 'ip_locked');

            return $this->respondError('Too many failed sign-in attempts from this network. Try again in 15 minutes.', 429);
        }

        $user = User::query()
            ->whereRaw('lower(email) = ?', [$username])
            ->orWhereRaw('lower(name) = ?', [$username])
            ->first();

        if ($user === null || ! Hash::check((string) $validated['password'], (string) $user->password)) {
            $this->recordFailedLogin($user, $username, $ip);

            return $this->respondError('Invalid credentials.', 401);
        }

        if ($this->managedUserIsLocked($user)) {
            $this->recordLoginAttempt($username, $user, $ip, false, 'account_locked');

            return $this->respondError('This account is locked. Contact your administrator.', 423);
        }

        if ($this->normalizeManagedUserStatus($user->status ?? 'active') !== 'active') {
            $this->recordLoginAttempt($username, $user, $ip, false, 'inactive_account');

            return $this->respondError('This account is inactive. Contact your administrator.', 403);
        }

        $activity = is_array($user->activity_log) ? $user->activity_log : [];
        $activity[] = $this->managedUserActivity('login', $user->email, []);
        $user->forceFill([
            'last_login_at' => now(),
            'failed_login_count' => 0,
            'locked_until' => null,
            'last_failed_login_at' => null,
            'activity_log' => array_slice($activity, -50),
        ])->save();
        $this->clearLoginIpFailures($ip);
        $this->recordLoginAttempt($username, $user, $ip, true, null);

        $tokens = $jwtAuth->issueTokens(
            $user->refresh(),
            (string) ($validated['platform'] ?? 'web'),
            $ip,
            (string) $request->userAgent()
        );

        return $this->respondData([
            ...$this->formatManagedUser($user->refresh(), includeActivity: true),
            'auth' => $tokens,
        ]);
    }

    public function refreshAuthToken(Request $request, JwtAuthService $jwtAuth): JsonResponse
    {
        $validated = $request->validate([
            'refreshToken' => ['required', 'string', 'max:255'],
            'platform' => ['nullable', 'string', 'max:30'],
        ]);

        $tokens = $jwtAuth->refresh(
            (string) $validated['refreshToken'],
            (string) ($validated['platform'] ?? 'web'),
            (string) $request->ip(),
            (string) $request->userAgent()
        );

        if ($tokens === null) {
            return $this->respondError('The refresh token is invalid or expired.', 401);
        }

        return $this->respondData(['auth' => $tokens]);
    }

    public function forgotManagedUserPassword(Request $request): JsonResponse
    {
        if (! $this->managedUsersTableAvailable() || ! Schema::hasTable('password_reset_tokens')) {
            return $this->respondError('Password reset is not available. Run migrations first.', 503);
        }

        $validated = $request->validate([
            'email' => ['required', 'email', 'max:255'],
        ]);
        $email = strtolower(trim((string) $validated['email']));
        $user = User::query()
            ->whereRaw('lower(email) = ?', [$email])
            ->first();

        if ($user !== null && $this->normalizeManagedUserStatus($user->status ?? 'active') === 'active') {
            $plainToken = Str::random(64);
            DB::table('password_reset_tokens')->updateOrInsert(
                ['email' => $email],
                [
                    'token' => Hash::make($plainToken),
                    'created_at' => now(),
                ],
            );

            $resetUrl = $this->passwordResetUrl($email, $plainToken);
            Mail::raw(
                "A password reset was requested for your PioneerPath account.\n\n".
                "Open this link within 60 minutes to set a new password:\n".$resetUrl."\n\n".
                'If you did not request this reset, contact your PioneerPath administrator.',
                function ($message) use ($email): void {
                    $message->to($email)
                        ->subject('Reset your PioneerPath password');
                }
            );

            $activity = is_array($user->activity_log) ? $user->activity_log : [];
            $activity[] = $this->managedUserActivity('password_reset_link_sent', 'system', [
                'expiresInMinutes' => 60,
            ]);
            $user->forceFill(['activity_log' => array_slice($activity, -50)])->save();
        }

        Log::channel('auth_events')->info('pioneerpath.password_reset_requested', [
            'email' => $this->maskPersonalLogValue($email),
            'matchedUser' => $user !== null,
            'ip' => $request->ip(),
        ]);

        return $this->respondData([
            'sent' => true,
            'message' => 'If that account exists, a password reset link has been sent.',
        ]);
    }

    public function resetManagedUserPasswordByToken(Request $request, JwtAuthService $jwtAuth): JsonResponse
    {
        if (! $this->managedUsersTableAvailable() || ! Schema::hasTable('password_reset_tokens')) {
            return $this->respondError('Password reset is not available. Run migrations first.', 503);
        }

        $validated = $request->validate([
            'email' => ['required', 'email', 'max:255'],
            'token' => ['required', 'string', 'max:255'],
            'password' => ['required', 'string', 'min:8', 'max:255'],
            'platform' => ['nullable', 'string', 'max:30'],
        ]);

        $email = strtolower(trim((string) $validated['email']));
        $resetRow = DB::table('password_reset_tokens')->where('email', $email)->first();
        if ($resetRow === null || ! Hash::check((string) $validated['token'], (string) $resetRow->token)) {
            return $this->respondError('This password reset link is invalid.', 422);
        }

        $createdAt = $resetRow->created_at !== null ? Carbon::parse($resetRow->created_at) : null;
        if ($createdAt === null || $createdAt->lt(now()->subMinutes(60))) {
            DB::table('password_reset_tokens')->where('email', $email)->delete();

            return $this->respondError('This password reset link has expired. Request a new one.', 422);
        }

        $user = User::query()->whereRaw('lower(email) = ?', [$email])->first();
        if ($user === null || $this->normalizeManagedUserStatus($user->status ?? 'active') !== 'active') {
            DB::table('password_reset_tokens')->where('email', $email)->delete();

            return $this->respondError('This account cannot be reset. Contact your administrator.', 403);
        }

        $activity = is_array($user->activity_log) ? $user->activity_log : [];
        $activity[] = $this->managedUserActivity('password_reset_completed', (string) $user->email, [
            'via' => 'email_link',
        ]);

        $user->forceFill([
            'password' => Hash::make((string) $validated['password']),
            'must_change_password' => false,
            'failed_login_count' => 0,
            'locked_until' => null,
            'last_failed_login_at' => null,
            'activity_log' => array_slice($activity, -50),
        ])->save();
        DB::table('password_reset_tokens')->where('email', $email)->delete();

        Log::channel('auth_events')->info('pioneerpath.password_reset_completed', [
            'email' => $this->maskPersonalLogValue($email),
            'userId' => $user->id,
            'ip' => $request->ip(),
        ]);

        $tokens = $jwtAuth->issueTokens(
            $user->refresh(),
            (string) ($validated['platform'] ?? 'web'),
            (string) $request->ip(),
            (string) $request->userAgent()
        );

        return $this->respondData([
            ...$this->formatManagedUser($user->refresh(), includeActivity: true),
            'auth' => $tokens,
        ]);
    }

    public function logoutManagedUser(Request $request, JwtAuthService $jwtAuth): JsonResponse
    {
        $token = (string) $request->bearerToken();
        if ($token !== '') {
            $jwtAuth->blacklist($token, 'logout');
        }

        $refreshToken = trim((string) $request->input('refreshToken', ''));
        if ($refreshToken !== '') {
            $jwtAuth->revokeRefreshToken($refreshToken);
        }

        return $this->respondData(['loggedOut' => true]);
    }

    public function changeManagedUserPassword(Request $request, JwtAuthService $jwtAuth): JsonResponse
    {
        /** @var User|null $user */
        $user = $request->attributes->get('auth_user');
        if ($user === null) {
            return $this->respondError('A valid sign-in token is required.', 401);
        }

        $validated = $request->validate([
            'currentPassword' => ['required', 'string', 'max:255'],
            'newPassword' => ['required', 'string', 'min:8', 'max:255'],
        ]);

        if (! Hash::check((string) $validated['currentPassword'], (string) $user->password)) {
            return $this->respondError('The current password is incorrect.', 422);
        }

        $activity = is_array($user->activity_log) ? $user->activity_log : [];
        $activity[] = $this->managedUserActivity('password_changed', (string) $user->email, []);
        $user->forceFill([
            'password' => Hash::make((string) $validated['newPassword']),
            'must_change_password' => false,
            'activity_log' => array_slice($activity, -50),
        ])->save();

        $tokens = $jwtAuth->issueTokens(
            $user->refresh(),
            (string) $request->input('platform', 'web'),
            (string) $request->ip(),
            (string) $request->userAgent()
        );

        return $this->respondData([
            ...$this->formatManagedUser($user->refresh(), includeActivity: true),
            'auth' => $tokens,
        ]);
    }

    public function manualDrivers(Request $request): JsonResponse
    {
        return $this->respondData($this->loadManualDrivers($request->query('status')));
    }

    public function manualDriver(string $driverId): JsonResponse
    {
        if (! $this->manualDriversTableAvailable()) {
            return $this->respondError('Manual drivers table is not available.', 503);
        }

        $driver = ManualDriver::query()->find($driverId);
        if ($driver === null) {
            return $this->respondError('Manual driver not found.', 404);
        }

        return $this->respondData($this->formatManualDriver($driver));
    }

    public function storeManualDriver(Request $request): JsonResponse
    {
        if (! $this->manualDriversTableAvailable()) {
            return $this->respondError('Manual drivers table is not available.', 503);
        }

        $validated = $request->validate([
            'name' => ['required', 'string', 'max:255'],
            'license' => ['nullable', 'string', 'max:120'],
            'phone' => ['nullable', 'string', 'max:80'],
            'email' => ['nullable', 'string', 'max:255'],
            'status' => ['nullable', 'string', 'max:80'],
            'baseSalary' => ['nullable', 'numeric'],
            'perTripBonus' => ['nullable', 'numeric'],
            'assignedVehicleGeotabId' => ['nullable', 'string', 'max:120'],
            'assignedVehiclePlate' => ['nullable', 'string', 'max:120'],
            'createLoginAccount' => ['nullable', 'boolean'],
            'temporaryPassword' => ['nullable', 'string', 'min:8', 'max:255'],
            'meta' => ['nullable', 'array'],
        ]);

        if (filter_var($validated['createLoginAccount'] ?? false, FILTER_VALIDATE_BOOL)
            && (! $this->managedUsersTableAvailable() || ! Schema::hasColumn('manual_drivers', 'user_id'))) {
            return $this->respondError('Run the driver account linking migration before creating driver login accounts.', 503);
        }

        $driver = ManualDriver::query()->create([
            'name' => trim((string) $validated['name']),
            'license' => trim((string) ($validated['license'] ?? '')),
            'phone' => trim((string) ($validated['phone'] ?? '')),
            'email' => trim((string) ($validated['email'] ?? '')),
            'status' => trim((string) ($validated['status'] ?? 'available')) ?: 'available',
            'base_salary' => $validated['baseSalary'] ?? null,
            'per_trip_bonus' => $validated['perTripBonus'] ?? null,
            'assigned_vehicle_geotab_id' => trim((string) ($validated['assignedVehicleGeotabId'] ?? '')) ?: null,
            'assigned_vehicle_plate' => trim((string) ($validated['assignedVehiclePlate'] ?? '')) ?: null,
            'meta' => $validated['meta'] ?? null,
        ]);
        $this->markManualDriverGeotabDirty($driver);

        $accountPayload = [];
        if (filter_var($validated['createLoginAccount'] ?? false, FILTER_VALIDATE_BOOL)) {
            $accountPayload = $this->createOrLinkManualDriverAccount(
                $driver->refresh(),
                $request,
                trim((string) ($validated['temporaryPassword'] ?? '')) ?: null,
            );
        }

        $this->storeCustomNotification(
            'driver',
            'Manual Driver Added',
            $driver->name.' was added to PioneerPath manual driver records.',
            ['driverId' => $driver->id],
        );
        $this->clearFleetCaches();

        return $this->respondData([
            ...$this->formatManualDriver($driver->refresh()),
            ...$accountPayload,
        ]);
    }

    public function deactivateManualDriver(Request $request, string $driverId): JsonResponse
    {
        if (! $this->manualDriversTableAvailable()) {
            return $this->respondError('Manual drivers table is not available.', 503);
        }

        $driver = ManualDriver::query()->find($driverId);
        if ($driver === null) {
            return $this->respondError('Manual driver not found.', 404);
        }
        if ($this->manualDriverHasActiveTrip($driver)) {
            return $this->respondError('Drivers assigned to active trips cannot be deactivated until those trips complete.', 423);
        }

        $validated = $request->validate([
            'reason' => ['required', 'string', 'max:1000'],
        ]);

        $meta = is_array($driver->meta) ? $driver->meta : [];
        $driver->forceFill([
            'status' => 'inactive',
            'meta' => [
                ...$meta,
                'deactivationReason' => $this->sanitizeText($validated['reason'], ''),
                'deactivatedAt' => now()->toIso8601String(),
            ],
        ])->save();
        $this->syncLinkedDriverAccount($driver->refresh());
        $this->markManualDriverGeotabDirty($driver);
        $this->clearFleetCaches();

        return $this->respondData($this->formatManualDriver($driver->refresh()));
    }

    public function createManualDriverAccount(Request $request, string $driverId): JsonResponse
    {
        if (! $this->manualDriversTableAvailable() || ! $this->managedUsersTableAvailable()) {
            return $this->respondError('Driver account linking requires manual drivers and managed users tables.', 503);
        }

        $driver = ManualDriver::query()->find($driverId);
        if ($driver === null) {
            return $this->respondError('Manual driver not found.', 404);
        }

        $validated = $request->validate([
            'temporaryPassword' => ['nullable', 'string', 'min:8', 'max:255'],
            'actor' => ['nullable', 'string', 'max:255'],
            'actorRole' => ['nullable', 'string'],
        ]);

        $accountPayload = $this->createOrLinkManualDriverAccount(
            $driver,
            $request,
            trim((string) ($validated['temporaryPassword'] ?? '')) ?: null,
        );
        $this->clearFleetCaches();

        return $this->respondData([
            ...$this->formatManualDriver($driver->refresh()),
            ...$accountPayload,
        ]);
    }

    public function resetManualDriverAccountPassword(Request $request, string $driverId): JsonResponse
    {
        if (! $this->manualDriversTableAvailable() || ! $this->managedUsersTableAvailable()) {
            return $this->respondError('Driver account linking requires manual drivers and managed users tables.', 503);
        }

        $driver = ManualDriver::query()->find($driverId);
        if ($driver === null) {
            return $this->respondError('Manual driver not found.', 404);
        }

        $user = $this->linkedUserForManualDriver($driver);
        if ($user === null) {
            return $this->respondError('Create a driver login account before resetting its password.', 422);
        }

        $actorRole = $this->actorManagedUserRole($request);
        if (! $this->managedUserCanManageRole($actorRole, 'driver')) {
            return $this->respondError('Your role cannot reset driver account passwords.', 403);
        }

        $validated = $request->validate([
            'actor' => ['nullable', 'string', 'max:255'],
            'actorRole' => ['nullable', 'string'],
        ]);
        $actor = $this->sanitizeText($validated['actor'] ?? $actorRole, $actorRole);
        $temporaryPassword = $this->generateTemporaryPassword();
        $activity = is_array($user->activity_log) ? $user->activity_log : [];
        $activity[] = $this->managedUserActivity('password_reset', $actor, [
            'driverId' => (string) $driver->id,
            'manualDriverName' => $driver->name,
            'temporaryPasswordIssued' => true,
        ]);

        $user->forceFill([
            'password' => Hash::make($temporaryPassword),
            'must_change_password' => true,
            'activity_log' => array_slice($activity, -50),
        ])->save();

        return $this->respondData([
            ...$this->formatManualDriver($driver->refresh()),
            'temporaryPassword' => $temporaryPassword,
            'temporaryPasswordShownOnce' => true,
        ]);
    }

    public function deleteManualDriver(string $driverId): JsonResponse
    {
        if (! $this->manualDriversTableAvailable()) {
            return $this->respondError('Manual drivers table is not available.', 503);
        }

        $driver = ManualDriver::query()->find($driverId);
        if ($driver === null) {
            return $this->respondError('Manual driver not found.', 404);
        }
        if ($this->manualDriverHasTripHistory($driver)) {
            return $this->respondError(
                'This driver has trip history and cannot be deleted. Use Deactivate instead to preserve records.',
                409
            );
        }
        if (Schema::hasTable('geotab_write_jobs')
            && GeotabWriteJob::query()
                ->where('local_type', 'manual_driver')
                ->where('local_id', (string) $driver->id)
                ->exists()) {
            return $this->respondError(
                'This driver has GeoTab sync history and cannot be deleted. Use Deactivate instead to preserve records.',
                409
            );
        }
        if ($this->linkedUserForManualDriver($driver) !== null) {
            return $this->respondError(
                'This driver has a login account. Use Deactivate instead to preserve account and audit history.',
                409
            );
        }

        $name = $driver->name;
        $driver->delete();
        $this->clearFleetCaches();
        $this->storeCustomNotification(
            'driver',
            'Manual Driver Deleted',
            $name.' was removed from PioneerPath manual driver records.',
            ['driverId' => $driverId, 'url' => '/drivers'],
        );

        return $this->respondData([
            'id' => $driverId,
            'deleted' => true,
        ]);
    }

    public function anonymizeManualDriver(Request $request, string $driverId): JsonResponse
    {
        if (! $this->manualDriversTableAvailable()) {
            return $this->respondError('Manual drivers table is not available.', 503);
        }
        if ($this->authenticatedRoleFromRequest($request) !== 'super_administrator') {
            return $this->respondError('Only Super Administrators can anonymize driver personal data.', 403);
        }

        $driver = ManualDriver::query()->find($driverId);
        if ($driver === null) {
            return $this->respondError('Manual driver not found.', 404);
        }
        if (! in_array(strtolower((string) $driver->status), ['inactive', 'deactivated'], true)) {
            return $this->respondError('Only deactivated drivers can be anonymized.', 422);
        }

        $validated = $request->validate([
            'reason' => ['required', 'string', 'max:1000'],
        ]);

        $meta = is_array($driver->meta) ? $driver->meta : [];
        $driver->forceFill([
            'license' => null,
            'phone' => null,
            'email' => null,
            'meta' => [
                ...$meta,
                'address' => null,
                'emergencyContact' => null,
                'anonymizedAt' => now()->toIso8601String(),
                'anonymizedBy' => $request->attributes->get('auth_user_id') ?: 'system',
                'anonymizationReason' => $this->sanitizeText($validated['reason'], ''),
            ],
        ])->save();

        $this->clearFleetCaches();
        $this->storeCustomNotification(
            'driver',
            'Driver Personal Data Anonymized',
            'A deactivated driver profile was anonymized while preserving trip history.',
            ['driverId' => $driver->id, 'url' => '/drivers'],
        );

        return $this->respondData($this->formatManualDriver($driver->refresh()));
    }

    public function updateManualDriver(Request $request, string $driverId): JsonResponse
    {
        if (! $this->manualDriversTableAvailable()) {
            return $this->respondError('Manual drivers table is not available.', 503);
        }

        $driver = ManualDriver::query()->find($driverId);
        if ($driver === null) {
            return $this->respondError('Manual driver not found.', 404);
        }

        $validated = $request->validate([
            'name' => ['nullable', 'string', 'max:255'],
            'license' => ['nullable', 'string', 'max:120'],
            'phone' => ['nullable', 'string', 'max:80'],
            'email' => ['nullable', 'string', 'max:255'],
            'status' => ['nullable', 'string', 'max:80'],
            'baseSalary' => ['nullable', 'numeric'],
            'perTripBonus' => ['nullable', 'numeric'],
            'assignedVehicleGeotabId' => ['nullable', 'string', 'max:120'],
            'assignedVehiclePlate' => ['nullable', 'string', 'max:120'],
            'createLoginAccount' => ['nullable', 'boolean'],
            'temporaryPassword' => ['nullable', 'string', 'min:8', 'max:255'],
            'meta' => ['nullable', 'array'],
        ]);

        if (filter_var($validated['createLoginAccount'] ?? false, FILTER_VALIDATE_BOOL)
            && (! $this->managedUsersTableAvailable() || ! Schema::hasColumn('manual_drivers', 'user_id'))) {
            return $this->respondError('Run the driver account linking migration before creating driver login accounts.', 503);
        }
        if (array_key_exists('email', $validated) && $this->managedUsersTableAvailable()) {
            $nextEmail = strtolower(trim((string) ($validated['email'] ?? '')));
            $linkedUser = $this->linkedUserForManualDriver($driver);
            if ($linkedUser !== null && $nextEmail !== '' && filter_var($nextEmail, FILTER_VALIDATE_EMAIL)) {
                $emailOwner = User::query()
                    ->whereRaw('LOWER(email) = ?', [$nextEmail])
                    ->whereKeyNot($linkedUser->id)
                    ->first();
                if ($emailOwner !== null) {
                    return $this->respondError('That email already belongs to another user account.', 422);
                }
            }
        }

        $driver->fill([
            'name' => isset($validated['name']) ? trim((string) $validated['name']) : $driver->name,
            'license' => array_key_exists('license', $validated) ? trim((string) ($validated['license'] ?? '')) : $driver->license,
            'phone' => array_key_exists('phone', $validated) ? trim((string) ($validated['phone'] ?? '')) : $driver->phone,
            'email' => array_key_exists('email', $validated) ? trim((string) ($validated['email'] ?? '')) : $driver->email,
            'status' => array_key_exists('status', $validated) ? (trim((string) ($validated['status'] ?? '')) ?: 'available') : $driver->status,
            'base_salary' => $validated['baseSalary'] ?? $driver->base_salary,
            'per_trip_bonus' => $validated['perTripBonus'] ?? $driver->per_trip_bonus,
            'assigned_vehicle_geotab_id' => array_key_exists('assignedVehicleGeotabId', $validated)
                ? (trim((string) ($validated['assignedVehicleGeotabId'] ?? '')) ?: null)
                : $driver->assigned_vehicle_geotab_id,
            'assigned_vehicle_plate' => array_key_exists('assignedVehiclePlate', $validated)
                ? (trim((string) ($validated['assignedVehiclePlate'] ?? '')) ?: null)
                : $driver->assigned_vehicle_plate,
            'meta' => $validated['meta'] ?? $driver->meta,
        ]);
        $driver->save();
        $this->markManualDriverGeotabDirty($driver);

        $accountPayload = [];
        if (filter_var($validated['createLoginAccount'] ?? false, FILTER_VALIDATE_BOOL)) {
            $accountPayload = $this->createOrLinkManualDriverAccount(
                $driver->refresh(),
                $request,
                trim((string) ($validated['temporaryPassword'] ?? '')) ?: null,
            );
        } elseif ($driver->user_id !== null) {
            $this->syncLinkedDriverAccount($driver->refresh());
        }

        $this->clearFleetCaches();

        return $this->respondData([
            ...$this->formatManualDriver($driver->refresh()),
            ...$accountPayload,
        ]);
    }

    public function maintenanceHistory(Request $request): JsonResponse
    {
        return $this->respondData($this->loadMaintenanceHistory([
            'vehicle' => $request->query('vehicle'),
            'type' => $request->query('type'),
            'dateFrom' => $request->query('dateFrom'),
            'dateTo' => $request->query('dateTo'),
        ]));
    }

    public function maintenanceHistoryRecord(string $historyId): JsonResponse
    {
        if (! $this->maintenanceHistoryTableAvailable()) {
            return $this->respondError('Maintenance history table is not available.', 503);
        }

        $history = MaintenanceHistory::query()->find($historyId);
        if ($history === null) {
            return $this->respondError('Maintenance record not found.', 404);
        }

        return $this->respondData($this->formatMaintenanceHistory($history));
    }

    public function storeMaintenanceHistory(Request $request): JsonResponse
    {
        if (! $this->maintenanceHistoryTableAvailable()) {
            return $this->respondError('Maintenance history table is not available.', 503);
        }

        $validated = $this->validateMaintenanceHistoryPayload($request);
        $history = MaintenanceHistory::query()->create($this->maintenanceHistoryAttributes($validated));
        $this->markMaintenanceGeotabDirty($history);

        $this->storeCustomNotification(
            'maintenance',
            'Maintenance History Added',
            ($history->vehicle_plate ?: 'Vehicle').' received a new maintenance history entry.',
            ['historyId' => $history->id],
        );
        $this->maybeStoreMaintenanceDueNotification($history);
        $this->clearFleetCaches();

        return $this->respondData($this->formatMaintenanceHistory($history));
    }

    public function updateMaintenanceHistory(Request $request, string $historyId): JsonResponse
    {
        if (! $this->maintenanceHistoryTableAvailable()) {
            return $this->respondError('Maintenance history table is not available.', 503);
        }

        $history = MaintenanceHistory::query()->find($historyId);
        if ($history === null) {
            return $this->respondError('Maintenance history record not found.', 404);
        }

        $validated = $this->validateMaintenanceHistoryPayload($request, partial: true);
        $source = strtolower((string) ($history->source ?? data_get($history->meta, 'source', 'manual')));
        $supplementOnly = $source === 'geotab' || $source === 'geotab_feed' || $source === 'geotab_sourced';
        if ($supplementOnly) {
            $allowed = array_intersect_key($validated, array_flip([
                'notes',
                'proofFileName',
                'proofFileType',
                'proofDataUrl',
                'meta',
            ]));
            if ($allowed === []) {
                return $this->respondError('GeoTab-sourced maintenance records are read-only. Add local remarks or proof only.', 423);
            }
            $validated = $allowed;
        }

        $history->fill($this->maintenanceHistoryAttributes($validated, $history));
        $history->save();
        $this->markMaintenanceGeotabDirty($history);
        $this->maybeStoreMaintenanceDueNotification($history);
        $this->clearFleetCaches();

        return $this->respondData($this->formatMaintenanceHistory($history));
    }

    public function maintenanceWorkOrderRecord(string $workOrderId): JsonResponse
    {
        if (! $this->maintenanceWorkOrderTableAvailable()) {
            return $this->respondError('Maintenance work order table is not available.', 503);
        }

        $workOrder = MaintenanceWorkOrder::query()->find($workOrderId);
        if ($workOrder === null) {
            return $this->respondError('Maintenance work order not found.', 404);
        }

        return $this->respondData($this->formatMaintenanceWorkOrder($workOrder));
    }

    public function storeMaintenanceWorkOrder(Request $request): JsonResponse
    {
        if (! $this->maintenanceWorkOrderTableAvailable()) {
            return $this->respondError('Maintenance work order table is not available.', 503);
        }

        $validated = $this->validateMaintenanceWorkOrderPayload($request);
        $sourceType = $this->normalizeWorkOrderSource((string) ($validated['sourceType'] ?? 'manual'));
        $sourceRecordId = $this->nullableCleanText($validated['sourceRecordId'] ?? '');

        if ($sourceRecordId !== null && $sourceType !== 'manual') {
            $existing = MaintenanceWorkOrder::query()
                ->where('source_type', $sourceType)
                ->where('source_record_id', $sourceRecordId)
                ->first();
            if ($existing !== null) {
                return $this->respondData($this->formatMaintenanceWorkOrder($existing));
            }
        }

        $attributes = $this->maintenanceWorkOrderAttributes($validated);
        $attributes['source_type'] = $sourceType;
        $attributes['source_record_id'] = $sourceRecordId;
        $attributes['audit_trail'] = [
            $this->maintenanceWorkOrderAudit('created', $this->maintenanceWorkOrderActor($request), [
                'status' => $attributes['status'] ?? 'open',
                'sourceType' => $sourceType,
                'sourceRecordId' => $sourceRecordId,
            ]),
        ];

        $workOrder = MaintenanceWorkOrder::query()->create($attributes);
        $this->storeCustomNotification(
            'maintenance',
            'Work Order Created',
            ($workOrder->vehicle_plate ?: 'Vehicle').' has a new maintenance work order.',
            ['workOrderId' => $workOrder->id, 'url' => '/maintenance'],
        );
        $this->clearFleetCaches();

        return $this->respondData($this->formatMaintenanceWorkOrder($workOrder));
    }

    public function updateMaintenanceWorkOrder(Request $request, string $workOrderId): JsonResponse
    {
        if (! $this->maintenanceWorkOrderTableAvailable()) {
            return $this->respondError('Maintenance work order table is not available.', 503);
        }

        $workOrder = MaintenanceWorkOrder::query()->find($workOrderId);
        if ($workOrder === null) {
            return $this->respondError('Maintenance work order not found.', 404);
        }

        if ($workOrder->status === 'voided') {
            return $this->respondError('Voided work orders are read-only.', 423);
        }

        $validated = $this->validateMaintenanceWorkOrderPayload($request, partial: true);
        $nextStatus = array_key_exists('status', $validated)
            ? $this->normalizeWorkOrderStatus((string) ($validated['status'] ?? $workOrder->status))
            : $workOrder->status;
        $lockedFinancially = in_array($workOrder->status, ['completed', 'verified'], true);
        if ($lockedFinancially) {
            $allowed = array_intersect_key($validated, array_flip(['notes', 'attachments', 'status', 'actualCost']));
            if ($allowed === []) {
                return $this->respondError('Completed work orders only allow notes, proof attachments, actual cost, or verification changes.', 423);
            }
            $validated = $allowed;
        }

        $beforeStatus = $workOrder->status;
        $workOrder->fill($this->maintenanceWorkOrderAttributes($validated, $workOrder));
        $this->applyWorkOrderStatusTimestamps($workOrder, $beforeStatus, $nextStatus);
        $trail = is_array($workOrder->audit_trail) ? $workOrder->audit_trail : [];
        $trail[] = $this->maintenanceWorkOrderAudit(
            $beforeStatus === $nextStatus ? 'updated' : 'status_changed',
            $this->maintenanceWorkOrderActor($request),
            ['from' => $beforeStatus, 'to' => $nextStatus],
        );
        $workOrder->audit_trail = array_slice($trail, -100);
        $workOrder->save();
        $this->clearFleetCaches();

        return $this->respondData($this->formatMaintenanceWorkOrder($workOrder));
    }

    public function storeMaintenanceWorkOrderAttachment(Request $request, string $workOrderId): JsonResponse
    {
        if (! $this->maintenanceWorkOrderTableAvailable()) {
            return $this->respondError('Maintenance work order table is not available.', 503);
        }

        $workOrder = MaintenanceWorkOrder::query()->find($workOrderId);
        if ($workOrder === null) {
            return $this->respondError('Maintenance work order not found.', 404);
        }

        $validated = $request->validate([
            'fileName' => ['required', 'string', 'max:255'],
            'fileType' => ['required', 'string', 'max:80'],
            'dataUrl' => ['required', 'string', 'max:14000000'],
            'kind' => ['nullable', 'string', 'max:80'],
            'notes' => ['nullable', 'string', 'max:1000'],
            'actor' => ['nullable', 'string', 'max:255'],
        ]);
        $this->validateProofDataUrl($validated['dataUrl'], 'dataUrl', requireDataUrl: true);

        $attachments = is_array($workOrder->attachments) ? $workOrder->attachments : [];
        $attachments[] = [
            'fileName' => $this->sanitizeText($validated['fileName'], 'attachment'),
            'fileType' => $this->sanitizeText($validated['fileType'], 'application/octet-stream'),
            'dataUrl' => $validated['dataUrl'],
            'kind' => $this->sanitizeText($validated['kind'] ?? 'proof', 'proof'),
            'notes' => $this->nullableCleanText($validated['notes'] ?? ''),
            'uploadedAt' => now()->toIso8601String(),
        ];
        $workOrder->attachments = $attachments;
        $trail = is_array($workOrder->audit_trail) ? $workOrder->audit_trail : [];
        $trail[] = $this->maintenanceWorkOrderAudit('attachment_added', $this->maintenanceWorkOrderActor($request), [
            'fileName' => $validated['fileName'],
        ]);
        $workOrder->audit_trail = array_slice($trail, -100);
        $workOrder->save();
        $this->clearFleetCaches();

        return $this->respondData($this->formatMaintenanceWorkOrder($workOrder));
    }

    public function deleteMaintenanceWorkOrderAttachment(Request $request, string $workOrderId, int $index): JsonResponse
    {
        if (! $this->maintenanceWorkOrderTableAvailable()) {
            return $this->respondError('Maintenance work order table is not available.', 503);
        }

        $workOrder = MaintenanceWorkOrder::query()->find($workOrderId);
        if ($workOrder === null) {
            return $this->respondError('Maintenance work order not found.', 404);
        }

        $attachments = is_array($workOrder->attachments) ? array_values($workOrder->attachments) : [];
        if (! array_key_exists($index, $attachments)) {
            return $this->respondError('Work order attachment not found.', 404);
        }

        $removed = $attachments[$index];
        array_splice($attachments, $index, 1);
        $workOrder->attachments = $attachments;
        $trail = is_array($workOrder->audit_trail) ? $workOrder->audit_trail : [];
        $trail[] = $this->maintenanceWorkOrderAudit('attachment_removed', $this->maintenanceWorkOrderActor($request), [
            'fileName' => $removed['fileName'] ?? 'attachment',
        ]);
        $workOrder->audit_trail = array_slice($trail, -100);
        $workOrder->save();
        $this->clearFleetCaches();

        return $this->respondData($this->formatMaintenanceWorkOrder($workOrder));
    }

    public function notificationPreferences(): JsonResponse
    {
        return $this->respondData($this->loadNotificationPreferences());
    }

    public function saveNotificationPreferences(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'browserEnabled' => ['nullable', 'boolean'],
            'emailEnabled' => ['nullable', 'boolean'],
            'tripAlerts' => ['nullable', 'boolean'],
            'maintenanceAlerts' => ['nullable', 'boolean'],
            'billingAlerts' => ['nullable', 'boolean'],
            'systemAlerts' => ['nullable', 'boolean'],
            'quietHours' => ['nullable', 'array'],
            'scope' => ['nullable', 'string', 'max:80'],
            'scopeKey' => ['nullable', 'string', 'max:120'],
            'meta' => ['nullable', 'array'],
        ]);

        if (! $this->notificationPreferencesTableAvailable()) {
            $preferences = $this->defaultNotificationPreferences();
            $merged = [
                ...$preferences,
                'browserEnabled' => $validated['browserEnabled'] ?? $preferences['browserEnabled'],
                'emailEnabled' => $validated['emailEnabled'] ?? $preferences['emailEnabled'],
                'tripAlerts' => $validated['tripAlerts'] ?? $preferences['tripAlerts'],
                'maintenanceAlerts' => $validated['maintenanceAlerts'] ?? $preferences['maintenanceAlerts'],
                'billingAlerts' => $validated['billingAlerts'] ?? $preferences['billingAlerts'],
                'systemAlerts' => $validated['systemAlerts'] ?? $preferences['systemAlerts'],
                'quietHours' => $validated['quietHours'] ?? $preferences['quietHours'],
                'meta' => $validated['meta'] ?? [],
            ];

            Cache::put('pioneer_notification_preferences_fallback', $merged, now()->addDays(14));

            return $this->respondData($merged);
        }

        $scope = trim((string) ($validated['scope'] ?? 'global')) ?: 'global';
        $scopeKey = trim((string) ($validated['scopeKey'] ?? 'default')) ?: 'default';
        $preference = NotificationPreference::query()->firstOrNew([
            'scope' => $scope,
            'scope_key' => $scopeKey,
        ]);
        $defaults = $this->defaultNotificationPreferences();

        $preference->fill([
            'browser_enabled' => $validated['browserEnabled'] ?? $preference->browser_enabled ?? $defaults['browserEnabled'],
            'email_enabled' => $validated['emailEnabled'] ?? $preference->email_enabled ?? $defaults['emailEnabled'],
            'trip_alerts' => $validated['tripAlerts'] ?? $preference->trip_alerts ?? $defaults['tripAlerts'],
            'maintenance_alerts' => $validated['maintenanceAlerts'] ?? $preference->maintenance_alerts ?? $defaults['maintenanceAlerts'],
            'billing_alerts' => $validated['billingAlerts'] ?? $preference->billing_alerts ?? $defaults['billingAlerts'],
            'system_alerts' => $validated['systemAlerts'] ?? $preference->system_alerts ?? $defaults['systemAlerts'],
            'quiet_hours' => $validated['quietHours'] ?? $preference->quiet_hours ?? $defaults['quietHours'],
            'meta' => $validated['meta'] ?? $preference->meta ?? [],
        ]);
        $preference->save();

        return $this->respondData($this->formatNotificationPreferences($preference));
    }

    public function pushConfig(): JsonResponse
    {
        return $this->respondData([
            'publicKey' => (string) config('services.web_push.public_key', ''),
            'webPushEnabled' => trim((string) config('services.web_push.public_key', '')) !== ''
                && trim((string) config('services.web_push.private_key', '')) !== '',
            'mobilePushEnabled' => trim((string) config('services.firebase.project_id', '')) !== '',
        ]);
    }

    public function storePushSubscription(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'platform' => ['nullable', 'string', 'max:40'],
            'endpoint' => ['required', 'string'],
            'keys' => ['nullable', 'array'],
            'contentEncoding' => ['nullable', 'string', 'in:aesgcm,aes128gcm'],
            'meta' => ['nullable', 'array'],
        ]);

        if (! Schema::hasTable('push_subscriptions')) {
            return $this->respondData([
                'registered' => false,
                'reason' => 'push_subscriptions table is not available yet.',
            ]);
        }

        $endpoint = trim((string) $validated['endpoint']);
        $endpointHash = hash('sha256', $endpoint);
        $subscription = PushSubscription::query()->updateOrCreate(
            ['endpoint_hash' => $endpointHash],
            [
                'endpoint' => $endpoint,
                'platform' => trim((string) ($validated['platform'] ?? 'web')) ?: 'web',
                'keys' => $validated['keys'] ?? [],
                'meta' => [
                    ...($validated['meta'] ?? []),
                    'contentEncoding' => $validated['contentEncoding'] ?? data_get($validated, 'meta.contentEncoding'),
                ],
                'last_seen_at' => now(),
            ],
        );

        return $this->respondData([
            'registered' => true,
            'endpointHash' => $subscription->endpoint_hash,
        ]);
    }

    public function deletePushSubscription(string $endpointHash): JsonResponse
    {
        if (Schema::hasTable('push_subscriptions')) {
            PushSubscription::query()->where('endpoint_hash', $endpointHash)->delete();
        }

        return $this->respondData(['deleted' => true]);
    }

    public function clientAssignments(): JsonResponse
    {
        return $this->respondData($this->loadClientAssignments());
    }

    public function storeClientAssignment(Request $request): JsonResponse
    {
        if (! $this->clientAssignmentsTableAvailable()) {
            return $this->respondError('Client assignments table is not available.', 503);
        }

        $validated = $request->validate([
            'clientName' => ['required', 'string', 'max:255'],
            'clientEmail' => ['nullable', 'string', 'max:255'],
            'clientPhone' => ['nullable', 'string', 'max:120'],
            'vehicleGeotabId' => ['nullable', 'string', 'max:120'],
            'vehiclePlate' => ['nullable', 'string', 'max:120'],
            'tripId' => ['nullable', 'string', 'max:120'],
            'status' => ['nullable', 'string', 'max:80'],
            'notes' => ['nullable', 'string'],
            'meta' => ['nullable', 'array'],
        ]);

        $assignment = ClientVehicleAssignment::query()->create([
            'client_name' => trim((string) $validated['clientName']),
            'client_email' => trim((string) ($validated['clientEmail'] ?? '')) ?: null,
            'client_phone' => trim((string) ($validated['clientPhone'] ?? '')) ?: null,
            'vehicle_geotab_id' => trim((string) ($validated['vehicleGeotabId'] ?? '')) ?: null,
            'vehicle_plate' => trim((string) ($validated['vehiclePlate'] ?? '')) ?: null,
            'trip_id' => trim((string) ($validated['tripId'] ?? '')) ?: null,
            'status' => trim((string) ($validated['status'] ?? 'active')) ?: 'active',
            'notes' => trim((string) ($validated['notes'] ?? '')) ?: null,
            'meta' => $validated['meta'] ?? null,
        ]);

        $this->clearFleetCaches();

        return $this->respondData($this->formatClientAssignment($assignment));
    }

    public function updateClientAssignment(Request $request, string $assignmentId): JsonResponse
    {
        if (! $this->clientAssignmentsTableAvailable()) {
            return $this->respondError('Client assignments table is not available.', 503);
        }

        $assignment = ClientVehicleAssignment::query()->find($assignmentId);
        if ($assignment === null) {
            return $this->respondError('Client assignment not found.', 404);
        }

        $validated = $request->validate([
            'clientName' => ['nullable', 'string', 'max:255'],
            'clientEmail' => ['nullable', 'string', 'max:255'],
            'clientPhone' => ['nullable', 'string', 'max:120'],
            'vehicleGeotabId' => ['nullable', 'string', 'max:120'],
            'vehiclePlate' => ['nullable', 'string', 'max:120'],
            'tripId' => ['nullable', 'string', 'max:120'],
            'status' => ['nullable', 'string', 'max:80'],
            'notes' => ['nullable', 'string'],
            'meta' => ['nullable', 'array'],
        ]);

        $assignment->fill([
            'client_name' => isset($validated['clientName']) ? trim((string) $validated['clientName']) : $assignment->client_name,
            'client_email' => array_key_exists('clientEmail', $validated) ? (trim((string) ($validated['clientEmail'] ?? '')) ?: null) : $assignment->client_email,
            'client_phone' => array_key_exists('clientPhone', $validated) ? (trim((string) ($validated['clientPhone'] ?? '')) ?: null) : $assignment->client_phone,
            'vehicle_geotab_id' => array_key_exists('vehicleGeotabId', $validated) ? (trim((string) ($validated['vehicleGeotabId'] ?? '')) ?: null) : $assignment->vehicle_geotab_id,
            'vehicle_plate' => array_key_exists('vehiclePlate', $validated) ? (trim((string) ($validated['vehiclePlate'] ?? '')) ?: null) : $assignment->vehicle_plate,
            'trip_id' => array_key_exists('tripId', $validated) ? (trim((string) ($validated['tripId'] ?? '')) ?: null) : $assignment->trip_id,
            'status' => isset($validated['status']) ? (trim((string) $validated['status']) ?: 'active') : $assignment->status,
            'notes' => array_key_exists('notes', $validated) ? (trim((string) ($validated['notes'] ?? '')) ?: null) : $assignment->notes,
            'meta' => $validated['meta'] ?? $assignment->meta,
        ]);
        $assignment->save();
        $this->clearFleetCaches();

        return $this->respondData($this->formatClientAssignment($assignment));
    }

    public function trips(Request $request): JsonResponse
    {
        $snapshot = $this->snapshot();
        $trips = is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [];

        if ($trips === []) {
            $routePlans = $this->geotabRoutesForFleetEndpoint($snapshot, empty($snapshot['routes'] ?? []));
            if ($routePlans !== []) {
                $trips = $this->plannedTripsFromRoutes($routePlans, []);
            }
        }

        return $this->respondData($this->privacyFilteredTripsForRequest($request, $trips));
    }

    public function trip(Request $request, string $tripId): JsonResponse
    {
        $trip = $this->findTrip($this->privacyFilteredTripsForRequest($request, $this->snapshot()['trips'] ?? []), $tripId);
        if ($trip === null) {
            return $this->respondError('Trip not found.', 404);
        }

        return $this->respondData($trip);
    }

    public function storeTrip(Request $request): JsonResponse
    {
        $customer = $this->sanitizeText($request->input('customer', ''), '');
        $origin = $this->sanitizeText($request->input('origin', ''), '');
        $destination = $this->sanitizeText($request->input('destination', ''), '');

        if ($customer === '' || $origin === '' || $destination === '') {
            return $this->respondError('Customer, origin, and destination are required.', 422);
        }

        $tripId = trim((string) $request->input('tripId', ''));
        if ($tripId === '') {
            $tripId = 'TRP-'.strtoupper(substr(Str::uuid()->toString(), 0, 6));
        }

        $scheduledDeparture = trim((string) $request->input('scheduledDepartureAt', ''));
        $estimatedArrival = trim((string) $request->input('estimatedArrivalAt', ''));
        $sortAt = $scheduledDeparture !== '' ? $scheduledDeparture : now()->toIso8601String();
        $displayDate = $scheduledDeparture !== ''
            ? $this->displayDate(Carbon::parse($scheduledDeparture))
            : $this->displayDate(now());
        $amount = $request->input('amount', 0);
        $orderValue = $request->input('orderValue', $amount);
        $freeDeliveryThreshold = $this->freeDeliveryThresholdForCustomer($customer);
        $requestedStatus = $this->normalizeWorkflowStatus($request->input('status', 'pending'));
        $initialWorkflowPhase = $requestedStatus === 'completed' ? 12 : 1;

        $state = $this->workflowState();
        $state['customTrips'][$tripId] = $this->formatWorkflowTrip([
            'tripId' => $tripId,
            'customer' => $customer,
            'phone' => trim((string) $request->input('phone', 'N/A')),
            'origin' => $origin,
            'destination' => $destination,
            'cargoType' => $this->sanitizeText($request->input('cargoType', 'General'), 'General'),
            'vehicle' => trim((string) $request->input('vehicle', '')),
            'driver' => trim((string) $request->input('driver', '')),
            'driverId' => trim((string) $request->input('driverId', $request->input('assignedDriverId', ''))),
            'assignedDriverId' => trim((string) $request->input('assignedDriverId', $request->input('driverId', ''))),
            'status' => $requestedStatus,
            'amount' => $amount,
            'orderValue' => $orderValue,
            'distanceKm' => $request->input('distanceKm', 0),
            'totalWeightKg' => $request->input('totalWeightKg', null),
            'scheduledDepartureAt' => $scheduledDeparture !== '' ? $scheduledDeparture : null,
            'estimatedArrivalAt' => $estimatedArrival !== '' ? $estimatedArrival : null,
            'specialInstructions' => trim((string) $request->input('specialInstructions', $request->input('notes', ''))),
            'freeDeliveryCandidate' => $this->parseMoney($orderValue) >= $freeDeliveryThreshold,
            'freeDeliveryThreshold' => $freeDeliveryThreshold,
            'fulfillmentMethod' => $request->input('fulfillmentMethod', null),
            'salesChannel' => $request->input('salesChannel', 'Viber'),
            'quotationStatus' => $request->input('quotationStatus', 'inquiry'),
            'poReceived' => filter_var($request->input('poReceived', false), FILTER_VALIDATE_BOOL),
            'notes' => trim((string) $request->input('notes', 'Created from dispatch workflow.')),
            'date' => $displayDate,
            'sortAt' => $sortAt,
            'workflowPhaseNumber' => $initialWorkflowPhase,
            'workflowPhaseLocked' => true,
            'startedAt' => null,
            'endedAt' => null,
            'routeName' => null,
            'routeGeotabId' => trim((string) $request->input('routeGeotabId', '')),
            'deviceGeotabId' => trim((string) $request->input('deviceGeotabId', '')),
            'routedPlaces' => [],
            'currentZone' => null,
            'originZone' => null,
            'destinationZone' => null,
            'arrivalState' => 'pending',
            'arrivedAtDestination' => false,
            'startPoint' => null,
            'stopPoint' => null,
        ]);
        $this->storeWorkflowState($state);
        $this->clearFleetCaches();
        $this->storeCustomNotification(
            'trip',
            'Trip Assigned',
            $tripId.' was assigned for '.$customer.'.',
            ['tripId' => $tripId, 'url' => '/trips'],
        );

        return $this->respondData($state['customTrips'][$tripId]);
    }

    public function updateTrip(Request $request, string $tripId): JsonResponse
    {
        $state = $this->workflowState();
        $customTrips = $state['customTrips'] ?? [];
        $updates = $this->workflowTripUpdates($request);
        $currentTrip = is_array($customTrips[$tripId] ?? null)
            ? $customTrips[$tripId]
            : (is_array($state['tripOverrides'][$tripId] ?? null) ? $state['tripOverrides'][$tripId] : []);
        $proposedTrip = array_merge($currentTrip, $updates);
        $transitionError = $this->workflowTransitionError($request, $proposedTrip);
        if ($transitionError !== null) {
            return $this->respondError($transitionError, 422);
        }

        if (isset($customTrips[$tripId]) && is_array($customTrips[$tripId])) {
            $customTrips[$tripId] = $this->formatWorkflowTrip(array_merge(
                $customTrips[$tripId],
                $updates
            ));
            $state['customTrips'] = $customTrips;
        } else {
            $state['tripOverrides'][$tripId] = array_merge(
                is_array($state['tripOverrides'][$tripId] ?? null) ? $state['tripOverrides'][$tripId] : [],
                $updates
            );
        }

        $this->storeWorkflowState($state);
        if ($request->has('workflowPhaseNumber')) {
            $this->queueWorkflowPhaseWriteBack(
                $tripId,
                is_array($customTrips[$tripId] ?? null)
                    ? $customTrips[$tripId]
                    : (is_array($state['tripOverrides'][$tripId] ?? null) ? $state['tripOverrides'][$tripId] : []),
                (int) $request->input('workflowPhaseNumber'),
            );
        }
        $this->clearFleetCaches();
        $this->syncAutomatedBillingForTripId($tripId, 'trip updated');
        if ($request->has('status')) {
            $this->storeCustomNotification(
                'dispatch',
                'Dispatch Status Changed',
                $tripId.' is now '.trim((string) $request->input('status', 'updated')).'.',
                ['tripId' => $tripId, 'status' => $request->input('status'), 'url' => '/dispatch-queue'],
            );
        }

        return $this->respondData($customTrips[$tripId] ?? [
            'tripId' => $tripId,
            'updated' => true,
        ]);
    }

    public function tripMap(Request $request, string $tripId): JsonResponse
    {
        $snapshot = $this->snapshot();
        $trip = $this->findTrip($snapshot['trips'], $tripId);
        if ($trip === null) {
            Log::channel('geotab')->info('PioneerPath trip map route resolution', [
                'tripId' => $tripId,
                'tripFound' => false,
                'gpsLogCountForTripId' => 0,
                'geotabFallbackAttempted' => false,
                'geotabFallbackLogRecordCount' => 0,
                'finalCoordinateCount' => 0,
                'routeSource' => 'none',
            ]);

            return $this->respondError('Trip not found.', 404);
        }
        if (! $this->canAccessTripLocationHistory($request, $trip)) {
            return $this->respondError('Your role is not allowed to access this trip location history.', 403);
        }

        $deviceId = trim((string) ($trip['deviceGeotabId'] ?? ''));
        $start = $this->parseDate($trip['startedAt'] ?? null);
        $end = $this->parseDate($trip['endedAt'] ?? null);
        $tripGpsLogCount = $this->gpsLogCountForTrip((string) ($trip['tripId'] ?? ''));
        $localTrail = $this->gpsTrailForTripWithSource($trip, $deviceId, $start, $end);
        $actualTrail = $localTrail['points'];
        $gpsTrailMaxPoints = max(10, (int) $this->systemSettingsValue('gps_trail_max_points', 200));
        if (count($actualTrail) > $gpsTrailMaxPoints) {
            $actualTrail = array_slice($actualTrail, -$gpsTrailMaxPoints);
        }
        $routeSource = $localTrail['source'];
        $geotabFallbackAttempted = false;
        $geotabFallbackCount = 0;

        if (count($actualTrail) < 2 && $deviceId !== '') {
            $geotabFallbackAttempted = true;
            $logs = $this->safeGet(fn () => $this->geotab->getGpsTrail(
                $deviceId,
                400,
                $start?->copy()->subMinutes(3),
                ($end ?? now())->copy()->addMinutes(3),
            ));
            $geotabFallbackCount = count($logs);

            $this->persistGpsTrailForTrip($logs, $trip, $deviceId);
            $fallbackTrail = $this->formatTrailPoints($logs);
            if (count($fallbackTrail) > $gpsTrailMaxPoints) {
                $fallbackTrail = array_slice($fallbackTrail, -$gpsTrailMaxPoints);
            }
            if (count($fallbackTrail) >= count($actualTrail)) {
                $actualTrail = $fallbackTrail;
                $routeSource = $actualTrail === [] ? 'none' : 'geotab_get_logrecord';
            }
        }

        $routeStops = is_array($trip['routedPlaces'] ?? null) ? $this->sanitizeRouteStops($trip['routedPlaces']) : [];
        $plannedPath = $this->plannedPathForTrip($trip, $routeStops);
        $rawGpsPointCount = count($actualTrail);
        $snapToRoads = [
            'snapped' => false,
            'source' => 'not_applied',
            'message' => 'Roads API snapping applies only to completed trips with actual GPS trails.',
        ];
        if (strtolower((string) ($trip['status'] ?? '')) === 'completed' && count($actualTrail) >= 2) {
            $snapResult = $this->googleMaps->snapCompletedTripTrail((string) ($trip['tripId'] ?? $tripId), $actualTrail);
            $actualTrail = $snapResult['points'];
            $snapToRoads = [
                'snapped' => $snapResult['snapped'],
                'source' => $snapResult['source'],
                'message' => $snapResult['message'],
            ];
            if ($snapResult['snapped']) {
                $routeSource = 'google_roads_snap_to_roads';
            }
        }
        $canRenderRoute = count($actualTrail) >= 2 || count($plannedPath) >= 2;

        Log::channel('geotab')->info('PioneerPath trip map route resolution', [
            'tripId' => $tripId,
            'tripFound' => true,
            'deviceGeotabId' => $deviceId,
            'gpsLogCountForTripId' => $tripGpsLogCount,
            'geotabFallbackAttempted' => $geotabFallbackAttempted,
            'geotabFallbackLogRecordCount' => $geotabFallbackCount,
            'finalCoordinateCount' => count($actualTrail),
            'plannedCoordinateCount' => count($plannedPath),
            'routeSource' => $routeSource,
        ]);

        return $this->respondData([
            'tripId' => $trip['tripId'],
            'status' => $trip['status'] ?? null,
            'vehicle' => $trip['vehicle'] ?? null,
            'driver' => $trip['driver'] ?? null,
            'routeName' => $trip['routeName'] ?? null,
            'origin' => $trip['origin'] ?? null,
            'destination' => $trip['destination'] ?? null,
            'startedAt' => $trip['startedAt'] ?? null,
            'endedAt' => $trip['endedAt'] ?? null,
            'actualTrail' => $actualTrail,
            'gpsPointCount' => count($actualTrail),
            'rawGpsPointCount' => $rawGpsPointCount,
            'routeSource' => $routeSource,
            'snapToRoads' => $snapToRoads,
            'routeAvailable' => $canRenderRoute,
            'actualRouteAvailable' => count($actualTrail) >= 2,
            'plannedRouteAvailable' => count($plannedPath) >= 2,
            'routeMessage' => match (true) {
                count($actualTrail) >= 2 => 'Actual GPS route ready',
                count($plannedPath) >= 2 => 'Showing planned route from trip start, stops, and destination.',
                default => ($geotabFallbackAttempted ? 'No GPS data recorded for this trip.' : 'Route data is loading.'),
            },
            'plannedPath' => $plannedPath,
            'geofences' => $this->plannedGeofencesFromStops($routeStops),
            'routeStops' => $routeStops,
            'startPoint' => $trip['startPoint'] ?? null,
            'stopPoint' => $trip['stopPoint'] ?? null,
        ]);
    }

    public function routes(Request $request): JsonResponse
    {
        $localRoutes = $this->localFleetRoutes();
        $snapshot = $this->snapshot();
        $geotabRoutes = $this->geotabRoutesForFleetEndpoint(
            $snapshot,
            $request->boolean('fresh') || empty($snapshot['routes'] ?? []),
        );

        return $this->respondData($this->mergeFleetRoutes($localRoutes, $geotabRoutes));
    }

    public function fleetRoute(string $routeId): JsonResponse
    {
        $route = $this->findFleetRoute($routeId);
        if ($route === null) {
            return $this->respondError('Fleet route not found.', 404);
        }

        return $this->respondData($this->formatFleetRoute($route->load('stops'), includeDeleted: true));
    }

    public function storeFleetRoute(Request $request): JsonResponse
    {
        if (! Schema::hasTable('fleet_routes')) {
            return $this->respondError('Fleet route storage is not available. Run migrations first.', 503);
        }

        $validated = $this->validateFleetRoutePayload($request);
        $route = DB::transaction(function () use ($validated): FleetRoute {
            $route = FleetRoute::query()->create([
                'name' => $this->sanitizeText($validated['name'], 'Untitled route'),
                'description' => $this->sanitizeText($validated['description'] ?? '', ''),
                'assigned_vehicle_geotab_id' => trim((string) ($validated['assignedVehicleGeotabId'] ?? '')) ?: null,
                'assigned_vehicle_plate' => trim((string) ($validated['assignedVehiclePlate'] ?? '')) ?: null,
                'status' => 'active',
                'sync_status' => 'not_staged',
                'meta' => $this->fleetRouteMetaFromPayload($validated, ['createdFrom' => 'route_crud']),
            ]);
            $this->replaceFleetRouteStops($route, $validated['stops']);

            return $route->refresh()->load('stops');
        });

        $this->markFleetRouteGeotabDirty($route);
        $this->clearFleetCaches();

        return $this->respondData($this->formatFleetRoute($route->refresh()->load('stops')));
    }

    public function updateFleetRoute(Request $request, string $routeId): JsonResponse
    {
        $route = $this->findFleetRoute($routeId);
        if ($route === null) {
            return $this->respondError('Fleet route not found.', 404);
        }
        if ($this->fleetRouteHasActiveTrip($route)) {
            return $this->respondError('Routes currently used by active trips are read-only until the trip completes.', 423);
        }

        $validated = $this->validateFleetRoutePayload($request, partial: true);
        $route = DB::transaction(function () use ($route, $validated): FleetRoute {
            $updates = [];
            if (array_key_exists('name', $validated)) {
                $updates['name'] = $this->sanitizeText($validated['name'], $route->name);
            }
            if (array_key_exists('description', $validated)) {
                $updates['description'] = $this->sanitizeText($validated['description'] ?? '', '');
            }
            if (array_key_exists('assignedVehicleGeotabId', $validated)) {
                $updates['assigned_vehicle_geotab_id'] = trim((string) ($validated['assignedVehicleGeotabId'] ?? '')) ?: null;
            }
            if (array_key_exists('assignedVehiclePlate', $validated)) {
                $updates['assigned_vehicle_plate'] = trim((string) ($validated['assignedVehiclePlate'] ?? '')) ?: null;
            }
            $updates['meta'] = $this->fleetRouteMetaFromPayload($validated, is_array($route->meta) ? $route->meta : []);
            $route->fill($updates);
            $route->save();

            if (array_key_exists('stops', $validated)) {
                $this->replaceFleetRouteStops($route, $validated['stops']);
            }

            return $route->refresh()->load('stops');
        });

        $this->markFleetRouteGeotabDirty($route);
        $this->clearFleetCaches();

        return $this->respondData($this->formatFleetRoute($route->refresh()->load('stops')));
    }

    public function deleteFleetRoute(string $routeId): JsonResponse
    {
        $route = $this->findFleetRoute($routeId);
        if ($route === null) {
            return $this->respondError('Fleet route not found.', 404);
        }
        if ($this->fleetRouteHasActiveTrip($route)) {
            return $this->respondError('Routes currently used by active trips cannot be deleted.', 423);
        }

        $route->forceFill([
            'status' => 'deleted',
            'deleted_at' => now(),
        ])->save();

        $this->markFleetRouteGeotabDirty($route->refresh()->load('stops'), 'route.remove');

        $this->clearFleetCaches();

        return $this->respondData($this->formatFleetRoute($route->refresh()->load('stops'), includeDeleted: true));
    }

    private function validateFleetRoutePayload(Request $request, bool $partial = false): array
    {
        return $request->validate([
            'name' => [$partial ? 'sometimes' : 'required', 'string', 'max:255'],
            'description' => ['nullable', 'string', 'max:2000'],
            'comment' => ['nullable', 'string', 'max:2000'],
            'routeType' => ['nullable', 'string', 'in:planned,unplanned,Planned,Unplanned'],
            'scheduledStartAt' => ['nullable', 'date'],
            'scheduledEndAt' => ['nullable', 'date', 'after_or_equal:scheduledStartAt'],
            'assignedVehicleGeotabId' => ['nullable', 'string', 'max:120'],
            'assignedVehiclePlate' => ['nullable', 'string', 'max:120'],
            'stops' => [$partial ? 'sometimes' : 'required', 'array', 'min:1'],
            'stops.*.name' => ['required_with:stops', 'string', 'max:255'],
            'stops.*.zoneId' => ['nullable', 'string', 'max:120'],
            'stops.*.latitude' => ['required_with:stops', 'numeric', 'between:-90,90'],
            'stops.*.longitude' => ['required_with:stops', 'numeric', 'between:-180,180'],
            'stops.*.estimatedStopDurationMinutes' => ['nullable', 'numeric', 'min:0', 'max:1440'],
        ]);
    }

    private function fleetRouteMetaFromPayload(array $payload, array $existing = []): array
    {
        $meta = $existing;
        if (array_key_exists('routeType', $payload)) {
            $meta['routeType'] = strtolower(trim((string) ($payload['routeType'] ?? 'planned'))) === 'unplanned'
                ? 'unplanned'
                : 'planned';
        } elseif (! isset($meta['routeType'])) {
            $meta['routeType'] = 'planned';
        }

        if (array_key_exists('comment', $payload)) {
            $comment = $this->sanitizeText($payload['comment'] ?? '', '');
            if ($comment === '') {
                unset($meta['comment']);
            } else {
                $meta['comment'] = $comment;
            }
        }

        foreach (['scheduledStartAt', 'scheduledEndAt'] as $key) {
            if (! array_key_exists($key, $payload)) {
                continue;
            }
            $value = trim((string) ($payload[$key] ?? ''));
            if ($value === '') {
                unset($meta[$key]);

                continue;
            }
            $meta[$key] = Carbon::parse($value)->toIso8601String();
        }

        return $meta;
    }

    private function replaceFleetRouteStops(FleetRoute $route, array $stops): void
    {
        FleetRouteStop::query()->where('fleet_route_id', $route->id)->delete();
        foreach (array_values($stops) as $index => $stop) {
            FleetRouteStop::query()->create([
                'fleet_route_id' => $route->id,
                'stop_sequence' => $index + 1,
                'stop_name' => $this->sanitizeText($stop['name'] ?? '', 'Stop '.($index + 1)),
                'geotab_zone_id' => trim((string) ($stop['zoneId'] ?? '')) ?: null,
                'latitude' => (float) ($stop['latitude'] ?? 0),
                'longitude' => (float) ($stop['longitude'] ?? 0),
                'estimated_stop_duration_minutes' => isset($stop['estimatedStopDurationMinutes'])
                    ? (int) round((float) $stop['estimatedStopDurationMinutes'])
                    : null,
            ]);
        }
    }

    private function localFleetRoutes(bool $includeDeleted = false): array
    {
        if (! Schema::hasTable('fleet_routes')) {
            return [];
        }

        $query = FleetRoute::query()->with('stops')->latest('updated_at');
        if (! $includeDeleted) {
            $query->where('status', '!=', 'deleted')->whereNull('deleted_at');
        }

        return $query->get()
            ->map(fn (FleetRoute $route): array => $this->formatFleetRoute($route))
            ->values()
            ->all();
    }

    /**
     * @param  array<string, mixed>  $snapshot
     * @return array<int, array<string, mixed>>
     */
    private function geotabRoutesForFleetEndpoint(array $snapshot, bool $preferFresh): array
    {
        if ($preferFresh) {
            $fresh = $this->freshGeotabRouteViews();
            if ($fresh !== []) {
                return $fresh;
            }
        }

        return array_values(array_map(
            fn (array $route): array => $this->normalizeImportedFleetRoute($route),
            array_filter(
                (array) ($snapshot['routes'] ?? []),
                fn (mixed $route): bool => is_array($route)
                    && ($route['managedLocally'] ?? false) !== true
                    && ($route['source'] ?? null) !== 'pioneer_route',
            ),
        ));
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function freshGeotabRouteViews(): array
    {
        if (! $this->geotab->isConfigured()) {
            return [];
        }

        $zones = $this->safeGet(fn () => $this->geotab->getZones(now(), 500), ['stage' => 'fleet_routes_fresh_zones']);
        $routes = $this->safeGet(fn () => $this->geotab->getRoutes(null, null, 500), ['stage' => 'fleet_routes_fresh_routes']);
        $routePlanItems = $this->safeGet(fn () => $this->geotab->getRoutePlanItems(null, null, 1000), ['stage' => 'fleet_routes_fresh_plan_items']);

        $zoneIndex = [];
        foreach ($zones as $zone) {
            if (! is_array($zone)) {
                continue;
            }
            $zoneId = $this->idFromValue($zone);
            if ($zoneId !== '') {
                $zoneIndex[$zoneId] = $zone;
            }
        }

        $routePlanItemsByRoute = $this->routePlanItemsByRoute($routePlanItems);
        $views = [];
        foreach ($routes as $route) {
            if (! is_array($route)) {
                continue;
            }
            $routeId = $this->idFromValue($route);
            $view = $this->formatRoute($route, $zoneIndex, $routePlanItemsByRoute[$routeId] ?? []);
            if ($view !== null) {
                $views[] = $this->normalizeImportedFleetRoute($view);
            }
        }

        if ($views !== []) {
            $this->feedHarvester->persistRouteStops($views);
        }

        return $views;
    }

    /**
     * @param  array<string, mixed>  $route
     * @return array<string, mixed>
     */
    private function normalizeImportedFleetRoute(array $route): array
    {
        $routeId = trim((string) ($route['geotabRouteId'] ?? $route['routeId'] ?? $route['id'] ?? ''));
        $name = $this->sanitizeText($route['name'] ?? $route['routeName'] ?? '', 'Unnamed Route');
        $stops = array_values(array_filter(
            array_map(fn (mixed $stop): ?array => is_array($stop) ? $this->normalizeImportedFleetRouteStop($stop) : null, (array) ($route['stops'] ?? $route['routedPlaces'] ?? [])),
        ));
        $plannedPath = (array) ($route['plannedPath'] ?? []);
        if ($plannedPath === [] && $stops !== []) {
            $plannedPath = array_values(array_filter(array_map(
                fn (array $stop): ?array => isset($stop['latitude'], $stop['longitude'])
                    ? ['latitude' => $stop['latitude'], 'longitude' => $stop['longitude']]
                    : null,
                $stops,
            )));
        }

        return [
            ...$route,
            'id' => $route['id'] ?? ($routeId !== '' ? 'geotab-route-'.$routeId : 'geotab-route-'.sha1($name.json_encode($plannedPath))),
            'routeId' => $routeId,
            'geotabRouteId' => $routeId,
            'name' => $name,
            'routeName' => $name,
            'assignedVehicle' => $this->sanitizeText($route['assignedVehicle'] ?? $route['assignedAsset'] ?? '', 'Unassigned'),
            'assignedVehiclePlate' => $route['assignedVehiclePlate'] ?? $route['assignedAsset'] ?? null,
            'assignedVehicleGeotabId' => $route['assignedVehicleGeotabId'] ?? $route['deviceId'] ?? null,
            'deviceId' => $route['deviceId'] ?? $route['assignedVehicleGeotabId'] ?? null,
            'status' => $route['status'] ?? 'active',
            'syncStatus' => 'synced',
            'syncLabel' => 'GeoTab: Up to date',
            'hasLocalGeotabChanges' => false,
            'canPushToGeotab' => false,
            'stopCount' => count($stops),
            'stops' => $stops,
            'routedPlaces' => $stops,
            'plannedPath' => $plannedPath,
            'routeAvailable' => count($plannedPath) >= 2 || count($stops) >= 2,
            'managedLocally' => false,
            'source' => $route['source'] ?? 'geotab_route_plan',
            'isRoutePlan' => true,
            'inUseByActiveTrip' => false,
            'readOnlyReason' => 'Imported from GeoTab. Edit it in MyGeotab or create a managed PioneerPath route.',
        ];
    }

    /**
     * @param  array<string, mixed>  $stop
     * @return array<string, mixed>
     */
    private function normalizeImportedFleetRouteStop(array $stop): array
    {
        $center = $this->coordinateParts($stop['center'] ?? null);
        $latitude = $stop['latitude'] ?? $center['latitude'] ?? null;
        $longitude = $stop['longitude'] ?? $center['longitude'] ?? null;

        return [
            ...$stop,
            'id' => (string) ($stop['id'] ?? $stop['zoneId'] ?? sha1(json_encode($stop))),
            'sequence' => (int) ($stop['sequence'] ?? 0),
            'name' => $this->sanitizeText($stop['name'] ?? '', 'Unknown Zone'),
            'zoneId' => $stop['zoneId'] ?? null,
            'latitude' => is_numeric($latitude) ? (float) $latitude : null,
            'longitude' => is_numeric($longitude) ? (float) $longitude : null,
            'estimatedStopDurationMinutes' => $stop['estimatedStopDurationMinutes'] ?? null,
            'center' => $center,
            'points' => is_array($stop['points'] ?? null) ? array_values($stop['points']) : [],
        ];
    }

    /**
     * Prefer locally managed route rows over their imported GeoTab equivalent.
     *
     * @param  array<int, array<string, mixed>>  $localRoutes
     * @param  array<int, array<string, mixed>>  $geotabRoutes
     * @return array<int, array<string, mixed>>
     */
    private function mergeFleetRoutes(array $localRoutes, array $geotabRoutes): array
    {
        $merged = [];
        $seen = [];

        foreach ([...$localRoutes, ...$geotabRoutes] as $route) {
            if (! is_array($route)) {
                continue;
            }

            $keys = $this->fleetRouteMergeKeys($route);
            $alreadyListed = false;
            foreach ($keys as $key) {
                if (isset($seen[$key])) {
                    $alreadyListed = true;
                    break;
                }
            }
            if ($alreadyListed) {
                continue;
            }

            $merged[] = $route;
            foreach ($keys as $key) {
                $seen[$key] = true;
            }
        }

        return $merged;
    }

    /**
     * @param  array<string, mixed>  $route
     * @return array<int, string>
     */
    private function fleetRouteMergeKeys(array $route): array
    {
        $keys = [];
        $geotabId = trim((string) ($route['geotabRouteId'] ?? $route['routeId'] ?? ''));
        if ($geotabId !== '' && ! str_starts_with($geotabId, 'local-route-')) {
            $keys[] = 'geotab:'.$geotabId;
        }

        $name = mb_strtolower(trim((string) ($route['name'] ?? $route['routeName'] ?? '')));
        $stops = $route['stops'] ?? $route['routedPlaces'] ?? [];
        if ($name !== '' && is_array($stops) && $stops !== []) {
            $stopKey = implode(';', array_map(
                fn (mixed $stop): string => is_array($stop)
                    ? trim((string) ($stop['zoneId'] ?? '')).':'.round((float) ($stop['latitude'] ?? data_get($stop, 'center.latitude', 0)), 5).','.round((float) ($stop['longitude'] ?? data_get($stop, 'center.longitude', 0)), 5)
                    : '',
                $stops,
            ));
            $keys[] = 'shape:'.sha1($name.'|'.$stopKey);
        }

        return $keys;
    }

    private function formatFleetRoute(FleetRoute $route, bool $includeDeleted = false): array
    {
        $stops = $route->stops
            ->sortBy('stop_sequence')
            ->values()
            ->map(fn (FleetRouteStop $stop): array => [
                'id' => (string) $stop->id,
                'sequence' => (int) $stop->stop_sequence,
                'name' => $this->sanitizeText($stop->stop_name, 'Stop '.$stop->stop_sequence),
                'zoneId' => $stop->geotab_zone_id,
                'latitude' => (float) $stop->latitude,
                'longitude' => (float) $stop->longitude,
                'estimatedStopDurationMinutes' => $stop->estimated_stop_duration_minutes,
            ])
            ->all();

        $inUse = $this->fleetRouteHasActiveTrip($route);
        $meta = is_array($route->meta) ? $route->meta : [];

        return [
            'id' => 'local-route-'.$route->id,
            'localId' => (string) $route->id,
            'name' => $this->sanitizeText($route->name, 'Untitled route'),
            'description' => $this->sanitizeText($route->description ?? '', ''),
            'comment' => $this->sanitizeText($meta['comment'] ?? '', ''),
            'routeType' => strtolower((string) ($meta['routeType'] ?? 'planned')) === 'unplanned' ? 'unplanned' : 'planned',
            'scheduledStartAt' => $meta['scheduledStartAt'] ?? null,
            'scheduledEndAt' => $meta['scheduledEndAt'] ?? null,
            'routeName' => $this->sanitizeText($route->name, 'Untitled route'),
            'assignedVehicle' => $this->sanitizeText($route->assigned_vehicle_plate ?? '', 'Unassigned'),
            'assignedVehiclePlate' => $route->assigned_vehicle_plate,
            'assignedVehicleGeotabId' => $route->assigned_vehicle_geotab_id,
            'deviceId' => $route->assigned_vehicle_geotab_id,
            'geotabRouteId' => $route->geotab_route_id,
            'status' => $route->status,
            'syncStatus' => $route->sync_status,
            'syncLabel' => $this->geotabSyncLabel($route->sync_status),
            'hasLocalGeotabChanges' => $route->sync_status === 'local_modified',
            'canPushToGeotab' => $route->sync_status === 'local_modified',
            'syncError' => $route->sync_error,
            'pendingWriteJobId' => $route->pending_write_job_id,
            'geotabSnapshot' => $route->geotab_snapshot,
            'lastUsedAt' => $route->last_used_at?->toIso8601String(),
            'deletedAt' => $includeDeleted ? $route->deleted_at?->toIso8601String() : null,
            'stopCount' => count($stops),
            'stops' => $stops,
            'routedPlaces' => $stops,
            'plannedPath' => array_map(fn (array $stop): array => [
                'latitude' => $stop['latitude'],
                'longitude' => $stop['longitude'],
            ], $stops),
            'routeAvailable' => count($stops) >= 2,
            'managedLocally' => true,
            'source' => 'pioneer_route',
            'isRoutePlan' => true,
            'inUseByActiveTrip' => $inUse,
            'readOnlyReason' => $inUse ? 'Route is used by an active trip.' : null,
            'createdAt' => $route->created_at?->toIso8601String(),
            'updatedAt' => $route->updated_at?->toIso8601String(),
        ];
    }

    private function findFleetRoute(string $routeId): ?FleetRoute
    {
        if (! Schema::hasTable('fleet_routes')) {
            return null;
        }

        $id = str_replace('local-route-', '', trim($routeId));
        if (! ctype_digit($id)) {
            return null;
        }

        return FleetRoute::query()->with('stops')->find((int) $id);
    }

    private function fleetRouteHasActiveTrip(FleetRoute $route): bool
    {
        $localIds = [(string) $route->id, 'local-route-'.$route->id];
        $geotabId = trim((string) $route->geotab_route_id);
        $activeStatuses = ['dispatched', 'inprogress', 'in progress', 'in transit', 'on trip', 'active'];

        foreach ($this->snapshot()['trips'] ?? [] as $trip) {
            $status = strtolower(trim((string) ($trip['status'] ?? '')));
            if (! in_array($status, $activeStatuses, true)) {
                continue;
            }

            $tripRouteLocalId = trim((string) ($trip['routeLocalId'] ?? $trip['fleetRouteId'] ?? ''));
            $tripRouteGeotabId = trim((string) ($trip['routeGeotabId'] ?? $trip['geotabRouteId'] ?? $trip['routeId'] ?? ''));
            if (in_array($tripRouteLocalId, $localIds, true) || ($geotabId !== '' && $tripRouteGeotabId === $geotabId)) {
                return true;
            }
        }

        return false;
    }

    private function stageFleetRouteWriteBack(FleetRoute $route, string $action, string $createdBy = 'fleet-manager'): void
    {
        if (! $this->writeBack->tableAvailable()) {
            return;
        }

        $payload = $this->fleetRouteWriteBackPayload($route, $action);
        if ($action !== 'route.remove' && $payload === []) {
            $route->forceFill([
                'sync_status' => trim((string) $route->assigned_vehicle_geotab_id) === '' ? 'not_staged' : 'local_modified',
                'sync_error' => trim((string) $route->assigned_vehicle_geotab_id) === ''
                    ? 'Assign a vehicle before pushing this route to GeoTab.'
                    : 'Add at least one route stop before pushing this route to GeoTab.',
                'pending_write_job_id' => null,
            ])->save();

            return;
        }

        $grouped = $this->fleetRouteDeviceAssignmentWriteBackPayload($route, $action, $payload);
        if ($grouped !== null) {
            $job = $this->writeBack->createJob(
                'group.route_device_assignment',
                'Route + Device Assignment',
                $grouped['payload'],
                'grouped_writeback',
                (string) $route->id,
                'route-device-assignment:fleet-route:'.$route->id.':'.sha1(json_encode($grouped['payload']).'|'.$route->updated_at?->toIso8601String()),
                $createdBy,
                $grouped['previewPayload'],
            );
        } else {
            $job = $this->writeBack->createJob(
                $action,
                'Route',
                $payload,
                'fleet_route',
                (string) $route->id,
                $action.':fleet-route:'.$route->id.':'.sha1(json_encode($payload).'|'.$route->updated_at?->toIso8601String()),
                $createdBy,
                $this->buildGeotabPreviewPayload('Route', $route->name, $payload, $route->geotab_snapshot ?? null),
            );
        }

        if ($job === null) {
            return;
        }

        $route->forceFill([
            'sync_status' => 'pending_approval',
            'sync_error' => null,
            'pending_write_job_id' => $job->id,
        ])->save();
    }

    private function fleetRouteWriteBackPayload(FleetRoute $route, string $action): array
    {
        $route->loadMissing('stops');
        if ($action === 'route.remove') {
            return ['routeId' => (string) $route->geotab_route_id, 'name' => $route->name];
        }

        $deviceId = trim((string) $route->assigned_vehicle_geotab_id);
        $orderedStops = $route->stops
            ->sortBy('stop_sequence')
            ->values();
        if ($deviceId === '' || $orderedStops->isEmpty()) {
            return [];
        }

        $routeEntity = [
            'name' => $route->name,
            'routeType' => 'Plan',
            'device' => ['id' => $deviceId],
        ];
        $meta = is_array($route->meta) ? $route->meta : [];
        $comment = $this->sanitizeText($meta['comment'] ?? $route->description ?? '', '');
        if ($comment !== '') {
            $routeEntity['comment'] = $comment;
        }
        if (trim((string) $route->geotab_route_id) !== '') {
            $routeEntity['id'] = (string) $route->geotab_route_id;
        }

        return [
            'route' => $routeEntity,
            'planItems' => $orderedStops
                ->map(function (FleetRouteStop $stop): array {
                    $zoneId = trim((string) $stop->geotab_zone_id);
                    $item = [
                        'zone' => [
                            'id' => $zoneId !== ''
                                ? $zoneId
                                : $this->routeStopZonePlaceholder($stop),
                        ],
                        'sequence' => max(0, (int) $stop->stop_sequence - 1),
                    ];
                    if ($stop->estimated_stop_duration_minutes !== null) {
                        $item['expectedStopDuration'] = (int) $stop->estimated_stop_duration_minutes * 60 * 1000;
                    }

                    return $item;
                })
                ->all(),
        ];
    }

    private function routeStopZonePlaceholder(FleetRouteStop $stop): string
    {
        return '$previous.zone:'.$stop->id;
    }

    private function routeStopZoneWriteBackPayload(FleetRoute $route, FleetRouteStop $stop): array
    {
        $latitude = (float) $stop->latitude;
        $longitude = (float) $stop->longitude;
        $buffer = 0.00009;
        $name = $this->sanitizeText($stop->stop_name, 'Route stop '.$stop->stop_sequence);

        return [
            'zone' => [
                'name' => trim($route->name.' - '.$name),
                'comment' => trim('Auto-created from PioneerPath route stop | Route: '.$route->name),
                'displayed' => true,
                'groups' => $this->geotabZoneGroups(),
                'points' => [
                    ['x' => $longitude - $buffer, 'y' => $latitude - $buffer],
                    ['x' => $longitude + $buffer, 'y' => $latitude - $buffer],
                    ['x' => $longitude + $buffer, 'y' => $latitude + $buffer],
                    ['x' => $longitude - $buffer, 'y' => $latitude + $buffer],
                ],
            ],
            'zoneType' => 'Customer Site',
            'routeStopId' => (string) $stop->id,
            'routeId' => (string) $route->id,
        ];
    }

    private function fleetRouteDeviceAssignmentWriteBackPayload(FleetRoute $route, string $routeAction, array $routePayload): ?array
    {
        if ($routeAction === 'route.remove' || $routePayload === []) {
            return null;
        }

        $deviceId = trim((string) $route->assigned_vehicle_geotab_id);
        if ($deviceId === '') {
            return null;
        }

        $routeOperationPayload = $routePayload;
        unset($routeOperationPayload['route']['device']);

        $zoneOperations = $route->stops
            ->sortBy('stop_sequence')
            ->filter(fn (FleetRouteStop $stop): bool => trim((string) $stop->geotab_zone_id) === '')
            ->values()
            ->map(function (FleetRouteStop $stop) use ($route): array {
                $payload = $this->routeStopZoneWriteBackPayload($route, $stop);

                return [
                    'action' => 'zone.create',
                    'entityType' => 'Route Stop Zone',
                    'entityName' => (string) data_get($payload, 'zone.name', 'Route stop zone'),
                    'localType' => 'fleet_route_stop',
                    'localId' => (string) $stop->id,
                    'payload' => $payload,
                    'snapshot' => [],
                    'localSnapshotPayload' => $payload,
                ];
            })
            ->all();

        $routeSnapshot = is_array($route->geotab_snapshot ?? null) ? $route->geotab_snapshot : [];
        $routeSnapshotForRollback = $routeSnapshot;
        unset($routeSnapshotForRollback['route']['device']);

        $assignmentPayload = [
            'routeId' => trim((string) $route->geotab_route_id) !== '' ? (string) $route->geotab_route_id : '$previous.geotabId',
            'deviceId' => $deviceId,
            'name' => (string) $route->name,
        ];
        $assignmentSnapshot = [
            'route' => is_array(data_get($routeSnapshot, 'route')) ? data_get($routeSnapshot, 'route') : [],
        ];

        $zonePreviews = array_map(
            fn (array $operation): array => $this->buildGeotabPreviewPayload(
                'Route Stop Zone',
                (string) ($operation['entityName'] ?? 'Route stop zone'),
                is_array($operation['payload'] ?? null) ? $operation['payload'] : [],
                null,
            ),
            $zoneOperations,
        );
        $routePreview = $this->buildGeotabPreviewPayload('Route', (string) $route->name, $routeOperationPayload, $routeSnapshotForRollback);
        $assignmentPreview = $this->buildGeotabPreviewPayload('Route Device Assignment', (string) ($route->assigned_vehicle_plate ?: $deviceId), $assignmentPayload, $assignmentSnapshot);
        $payload = [
            'groupType' => $zoneOperations === [] ? 'route_device_assignment' : 'route_stop_zones_route_device_assignment',
            'operations' => [
                ...$zoneOperations,
                [
                    'action' => $routeAction,
                    'entityType' => 'Route',
                    'entityName' => (string) $route->name,
                    'localType' => 'fleet_route',
                    'localId' => (string) $route->id,
                    'payload' => $routeOperationPayload,
                    'snapshot' => $routeSnapshotForRollback,
                    'localSnapshotPayload' => $routePayload,
                ],
                [
                    'action' => 'route.assign_device',
                    'entityType' => 'Route Device Assignment',
                    'entityName' => (string) ($route->assigned_vehicle_plate ?: $deviceId),
                    'localType' => 'fleet_route',
                    'localId' => (string) $route->id,
                    'payload' => $assignmentPayload,
                    'snapshot' => $assignmentSnapshot,
                    'localSnapshotPayload' => $routePayload,
                ],
            ],
            'assignment' => [
                'routeName' => (string) $route->name,
                'vehiclePlate' => (string) ($route->assigned_vehicle_plate ?: ''),
                'deviceId' => $deviceId,
                'autoCreatedZoneCount' => count($zoneOperations),
            ],
        ];

        return [
            'payload' => $payload,
            'previewPayload' => $this->buildGroupedGeotabPreviewPayload(
                trim((string) $route->name).' + '.trim((string) ($route->assigned_vehicle_plate ?: $deviceId)),
                $payload,
                [...$zonePreviews, $routePreview, $assignmentPreview],
            ),
        ];
    }

    private function markFleetRouteGeotabDirty(FleetRoute $route, ?string $forcedAction = null): void
    {
        $action = $forcedAction ?: ($route->geotab_route_id ? 'route.update' : 'route.create');
        $payload = $this->fleetRouteWriteBackPayload($route, $action);
        $route->forceFill([
            'sync_status' => $this->payloadMatchesGeotabSnapshot($payload, $route->geotab_snapshot ?? null) ? 'synced' : 'local_modified',
            'sync_error' => null,
            'pending_write_job_id' => null,
        ])->save();
    }

    public function pushFleetRouteToGeotab(Request $request, string $routeId): JsonResponse
    {
        $route = $this->findFleetRoute($routeId);
        if ($route === null) {
            return $this->respondError('Fleet route not found.', 404);
        }

        $action = $route->status === 'deleted' ? 'route.remove' : ($route->geotab_route_id ? 'route.update' : 'route.create');
        $payload = $this->fleetRouteWriteBackPayload($route, $action);
        if ($payload === []) {
            return $this->respondError('Assign a vehicle before pushing this route to GeoTab.', 422);
        }
        if ($this->payloadMatchesGeotabSnapshot($payload, $route->geotab_snapshot ?? null)) {
            return $this->respondData([
                ...$this->formatFleetRoute($route->load('stops'), includeDeleted: true),
                'geotabAlreadyUpToDate' => true,
                'message' => 'GeoTab is already up to date.',
            ]);
        }
        if ($this->isGeotabPreviewRequest($request)) {
            $grouped = $this->fleetRouteDeviceAssignmentWriteBackPayload($route, $action, $payload);

            return $this->respondData([
                ...$this->formatFleetRoute($route->load('stops'), includeDeleted: true),
                ...$this->pendingGeotabPushMetadata('fleet_route', (string) $route->id),
                'message' => 'Review this GeoTab payload before staging it for approval.',
                'previewOnly' => true,
                'preview' => $grouped['payload'] ?? $payload,
                'previewPayload' => $grouped['previewPayload'] ?? $this->buildGeotabPreviewPayload('Route', $route->name, $payload, $route->geotab_snapshot ?? null),
            ]);
        }

        $this->stageFleetRouteWriteBack($route, $action, $this->geotabActorFromRequest($request));
        $this->clearFleetCaches();

        return $this->respondData([
            ...$this->formatFleetRoute($route->refresh()->load('stops'), includeDeleted: true),
            'message' => 'GeoTab push request staged for admin approval.',
            'preview' => $payload,
        ]);
    }

    private function validateFleetZonePayload(Request $request, bool $partial = false): array
    {
        return $request->validate([
            'name' => [$partial ? 'sometimes' : 'required', 'string', 'max:255'],
            'zoneType' => ['nullable', 'string', 'max:80'],
            'boundaryPoints' => [$partial ? 'sometimes' : 'required', 'array', 'min:3'],
            'boundaryPoints.*.latitude' => ['required_with:boundaryPoints', 'numeric', 'between:-90,90'],
            'boundaryPoints.*.longitude' => ['required_with:boundaryPoints', 'numeric', 'between:-180,180'],
            'centerLatitude' => ['nullable', 'numeric', 'between:-90,90'],
            'centerLongitude' => ['nullable', 'numeric', 'between:-180,180'],
            'clientId' => ['nullable', 'string', 'max:120'],
            'clientName' => ['nullable', 'string', 'max:255'],
            'notes' => ['nullable', 'string', 'max:2000'],
        ]);
    }

    private function readableZoneType(mixed $raw): string
    {
        $value = trim((string) ($raw ?? ''));
        if ($value === '') {
            return 'Custom Zone';
        }

        $labels = [
            'ZoneTypeCustomerId' => 'Customer Site',
            'ZoneTypeHomeId' => 'Home Base',
            'ZoneTypeOfficeId' => 'Office',
            'ZoneTypeServiceId' => 'Service Center',
            'Customer Site' => 'Customer Site',
            'Home Base' => 'Home Base',
            'Office' => 'Office',
            'Service Center' => 'Service Center',
            'Depot' => 'Depot',
            'Restricted Area' => 'Restricted Area',
            'Rest Stop' => 'Rest Stop',
            'Custom Zone' => 'Custom Zone',
            'Other' => 'Custom Zone',
        ];

        return $labels[$value] ?? 'Custom Zone';
    }

    private function normalizedZonePoints(array $points): array
    {
        return array_values(array_map(fn (array $point): array => [
            'latitude' => round((float) ($point['latitude'] ?? 0), 7),
            'longitude' => round((float) ($point['longitude'] ?? 0), 7),
        ], $points));
    }

    private function zoneCenterFromPoints(array $points, mixed $latitude = null, mixed $longitude = null): array
    {
        if (is_numeric($latitude) && is_numeric($longitude)) {
            return [
                'latitude' => round((float) $latitude, 7),
                'longitude' => round((float) $longitude, 7),
            ];
        }

        if ($points === []) {
            return ['latitude' => null, 'longitude' => null];
        }

        return [
            'latitude' => round(array_sum(array_map(fn (array $point): float => (float) ($point['latitude'] ?? 0), $points)) / count($points), 7),
            'longitude' => round(array_sum(array_map(fn (array $point): float => (float) ($point['longitude'] ?? 0), $points)) / count($points), 7),
        ];
    }

    private function fleetZoneClient(mixed $clientId): ?FleetClient
    {
        if (! Schema::hasTable('fleet_clients')) {
            return null;
        }

        $id = trim((string) ($clientId ?? ''));
        if ($id === '') {
            return null;
        }
        $id = str_replace('client-', '', $id);
        if (! ctype_digit($id)) {
            return null;
        }

        return FleetClient::query()->find((int) $id);
    }

    private function localFleetZones(bool $includeDeleted = false): array
    {
        if (! Schema::hasTable('fleet_zones')) {
            return [];
        }

        $query = FleetZone::query()->latest('updated_at');
        if (! $includeDeleted) {
            $query->where('status', '!=', 'deleted')->whereNull('deleted_at');
        }

        return $query->get()->map(fn (FleetZone $zone): array => $this->formatFleetZone($zone))->values()->all();
    }

    /**
     * @param  array<string, mixed>  $snapshot
     * @return array<int, array<string, mixed>>
     */
    private function geotabZonesForFleetEndpoint(array $snapshot, bool $preferFresh): array
    {
        if ($preferFresh) {
            $fresh = $this->freshGeotabZoneViews();
            if ($fresh !== []) {
                return $fresh;
            }
        }

        $snapshotZones = array_filter(
            (array) ($snapshot['zones'] ?? []),
            fn (mixed $zone): bool => is_array($zone)
                && ($zone['managedLocally'] ?? false) !== true
                && ($zone['source'] ?? null) !== 'pioneer_zone',
        );

        return array_values(array_map(
            fn (array $zone): array => $this->normalizeImportedFleetZone($zone),
            $snapshotZones,
        ));
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function freshGeotabZoneViews(): array
    {
        if (! $this->geotab->isConfigured()) {
            return [];
        }

        $zones = $this->safeGet(fn () => $this->geotab->getZones(now(), 1000), ['stage' => 'fleet_zones_fresh']);

        return array_values(array_filter(array_map(
            fn (mixed $zone): ?array => is_array($zone)
                ? $this->normalizeImportedFleetZone($this->formatZone($zone))
                : null,
            $zones,
        )));
    }

    /**
     * @param  array<string, mixed>  $zone
     * @return array<string, mixed>
     */
    private function normalizeImportedFleetZone(array $zone): array
    {
        $points = $this->normalizedZonePoints(
            is_array($zone['boundaryPoints'] ?? null)
                ? $zone['boundaryPoints']
                : (is_array($zone['points'] ?? null) ? $zone['points'] : []),
        );
        $center = $this->zoneCenterFromPoints(
            $points,
            $zone['centerLatitude'] ?? data_get($zone, 'center.latitude'),
            $zone['centerLongitude'] ?? data_get($zone, 'center.longitude'),
        );
        $geotabId = trim((string) ($zone['geotabZoneId'] ?? $zone['zoneId'] ?? $zone['id'] ?? ''));
        $type = $this->readableZoneType($zone['zoneType'] ?? $zone['type'] ?? null);

        return [
            ...$zone,
            'id' => $zone['id'] ?? ($geotabId !== '' ? 'geotab-zone-'.$geotabId : 'geotab-zone-'.sha1(($zone['name'] ?? '').json_encode($points))),
            'zoneId' => $geotabId,
            'geotabZoneId' => $geotabId,
            'name' => $this->sanitizeText($zone['name'] ?? '', 'Unnamed Zone'),
            'comment' => $this->sanitizeText($zone['comment'] ?? $zone['notes'] ?? '', ''),
            'type' => $type,
            'zoneType' => $type,
            'clientId' => $zone['clientId'] ?? null,
            'clientName' => $zone['clientName'] ?? null,
            'clientAssociation' => $zone['clientAssociation'] ?? $zone['clientName'] ?? null,
            'notes' => $zone['notes'] ?? $zone['comment'] ?? null,
            'center' => $center,
            'centerLatitude' => $center['latitude'],
            'centerLongitude' => $center['longitude'],
            'points' => $points,
            'boundaryPoints' => $points,
            'displayed' => $zone['displayed'] ?? true,
            'status' => $zone['status'] ?? 'active',
            'syncStatus' => 'synced',
            'syncLabel' => 'GeoTab: Up to date',
            'hasLocalGeotabChanges' => false,
            'canPushToGeotab' => false,
            'managedLocally' => false,
            'source' => $zone['source'] ?? 'geotab_zone',
        ];
    }

    /**
     * Prefer locally managed zone rows over their imported GeoTab equivalent.
     * Local rows retain edit/sync state and must not be displayed twice.
     *
     * @param  array<int, array<string, mixed>>  $localZones
     * @param  array<int, array<string, mixed>>  $geotabZones
     * @return array<int, array<string, mixed>>
     */
    private function mergeFleetZones(array $localZones, array $geotabZones): array
    {
        $merged = [];
        $seen = [];

        foreach ([...$localZones, ...$geotabZones] as $zone) {
            if (! is_array($zone)) {
                continue;
            }

            $keys = $this->fleetZoneMergeKeys($zone);
            $alreadyListed = false;
            foreach ($keys as $key) {
                if (isset($seen[$key])) {
                    $alreadyListed = true;
                    break;
                }
            }
            if ($alreadyListed) {
                continue;
            }

            $merged[] = $zone;
            foreach ($keys as $key) {
                $seen[$key] = true;
            }
        }

        return $merged;
    }

    /**
     * @param  array<string, mixed>  $zone
     * @return array<int, string>
     */
    private function fleetZoneMergeKeys(array $zone): array
    {
        $keys = [];
        $geotabId = trim((string) ($zone['geotabZoneId'] ?? $zone['zoneId'] ?? ''));
        if ($geotabId !== '' && ! str_starts_with($geotabId, 'local-zone-')) {
            $keys[] = 'geotab:'.$geotabId;
        }

        $name = trim((string) ($zone['name'] ?? ''));
        $points = $zone['points'] ?? $zone['boundaryPoints'] ?? [];
        if ($name !== '' && is_array($points) && $points !== []) {
            $keys[] = 'boundary:'.FleetZone::dedupeKey($name, $points);
        }

        return $keys;
    }

    private function formatFleetZone(FleetZone $zone, bool $includeDeleted = false): array
    {
        $points = $this->normalizedZonePoints(is_array($zone->boundary_points) ? $zone->boundary_points : []);
        $center = $this->zoneCenterFromPoints($points, $zone->center_latitude, $zone->center_longitude);
        $syncStatus = $zone->sync_status ?: 'not_staged';

        return [
            'id' => 'local-zone-'.$zone->id,
            'localId' => (string) $zone->id,
            'zoneId' => $zone->geotab_zone_id ?: 'local-zone-'.$zone->id,
            'geotabZoneId' => $zone->geotab_zone_id,
            'name' => $this->sanitizeText($zone->name, 'Untitled zone'),
            'type' => $this->readableZoneType($zone->zone_type),
            'zoneType' => $this->readableZoneType($zone->zone_type),
            'clientId' => $zone->fleet_client_id,
            'clientName' => $zone->client_name,
            'clientAssociation' => $zone->client_name,
            'notes' => is_array($zone->meta) ? ($zone->meta['notes'] ?? null) : null,
            'meta' => $zone->meta,
            'center' => $center,
            'centerLatitude' => $center['latitude'],
            'centerLongitude' => $center['longitude'],
            'points' => $points,
            'boundaryPoints' => $points,
            'displayed' => true,
            'status' => $zone->status,
            'syncStatus' => $syncStatus,
            'syncLabel' => $this->geotabSyncLabel($syncStatus),
            'hasLocalGeotabChanges' => $syncStatus === 'local_modified' || $zone->geotab_snapshot === null,
            'canPushToGeotab' => in_array($syncStatus, ['local_modified', 'not_staged', 'not_synced'], true) || $zone->geotab_snapshot === null,
            'syncError' => $zone->sync_error,
            'pendingWriteJobId' => $zone->pending_write_job_id,
            'geotabSnapshot' => $zone->geotab_snapshot,
            'managedLocally' => true,
            'source' => 'pioneer_zone',
            'deletedAt' => $includeDeleted ? $zone->deleted_at?->toIso8601String() : null,
            'createdAt' => $zone->created_at?->toIso8601String(),
            'updatedAt' => $zone->updated_at?->toIso8601String(),
        ];
    }

    private function findFleetZone(string $zoneId): ?FleetZone
    {
        if (! Schema::hasTable('fleet_zones')) {
            return null;
        }

        $id = str_replace('local-zone-', '', trim($zoneId));
        if (! ctype_digit($id)) {
            return null;
        }

        return FleetZone::query()->find((int) $id);
    }

    private function stageFleetZoneWriteBack(FleetZone $zone, string $action, string $createdBy = 'fleet-manager'): void
    {
        if (! $this->writeBack->tableAvailable()) {
            return;
        }

        $payload = $this->fleetZoneWriteBackPayload($zone, $action);

        $grouped = $this->fleetZoneDeviceAssignmentWriteBackPayload($zone, $action, $payload);
        if ($grouped !== null) {
            $job = $this->writeBack->createJob(
                'group.zone_device_assignment',
                'Zone + Device Assignment',
                $grouped['payload'],
                'grouped_writeback',
                (string) $zone->id,
                'zone-device-assignment:fleet-zone:'.$zone->id.':'.sha1(json_encode($grouped['payload']).'|'.$zone->updated_at?->toIso8601String()),
                $createdBy,
                $grouped['previewPayload'],
            );
        } else {
            $job = $this->writeBack->createJob(
                $action,
                'Zone',
                $payload,
                'fleet_zone',
                (string) $zone->id,
                $action.':fleet-zone:'.$zone->id.':'.sha1(json_encode($payload).'|'.$zone->updated_at?->toIso8601String()),
                $createdBy,
                $this->buildGeotabPreviewPayload('Zone', $zone->name, $payload, $zone->geotab_snapshot ?? null),
            );
        }

        if ($job === null) {
            return;
        }

        $zone->forceFill([
            'sync_status' => 'pending_approval',
            'sync_error' => null,
            'pending_write_job_id' => $job->id,
        ])->save();

        if (($grouped['vehicle'] ?? null) instanceof ManualVehicle) {
            $grouped['vehicle']->forceFill([
                'sync_status' => 'pending_approval',
                'sync_error' => null,
                'pending_write_job_id' => $job->id,
            ])->saveQuietly();
        }
    }

    private function fleetZoneWriteBackPayload(FleetZone $zone, string $action): array
    {
        if ($action === 'zone.remove') {
            return ['zoneId' => (string) $zone->geotab_zone_id, 'name' => $zone->name];
        }

        $points = $this->normalizedZonePoints(is_array($zone->boundary_points) ? $zone->boundary_points : []);
        $zoneEntity = [
            'name' => $zone->name,
            'comment' => trim(implode(' | ', array_filter([
                $this->readableZoneType($zone->zone_type),
                $zone->client_name ? 'Client: '.$zone->client_name : null,
            ]))),
            'displayed' => true,
            'groups' => $this->geotabZoneGroups(),
            'points' => array_map(fn (array $point): array => [
                'x' => (float) $point['longitude'],
                'y' => (float) $point['latitude'],
            ], $points),
        ];
        if (trim((string) $zone->geotab_zone_id) !== '') {
            $zoneEntity['id'] = (string) $zone->geotab_zone_id;
        }

        return ['zone' => $zoneEntity, 'zoneType' => $this->readableZoneType($zone->zone_type)];
    }

    private function fleetZoneDeviceAssignmentWriteBackPayload(FleetZone $zone, string $zoneAction, array $zonePayload): ?array
    {
        if ($zoneAction === 'zone.remove' || trim((string) $zone->client_name) === '' || ! Schema::hasTable('client_vehicle_assignments')) {
            return null;
        }

        $assignment = ClientVehicleAssignment::query()
            ->where('status', 'active')
            ->whereNotNull('vehicle_geotab_id')
            ->where('vehicle_geotab_id', '!=', '')
            ->where(function (Builder $query) use ($zone): void {
                $query->where('client_name', $zone->client_name);
                if ($zone->client !== null) {
                    $query->orWhere('client_name', $zone->client->company_name);
                }
            })
            ->latest('updated_at')
            ->first();

        if ($assignment === null) {
            return null;
        }

        $deviceId = trim((string) $assignment->vehicle_geotab_id);
        $vehicle = null;
        if (Schema::hasTable('manual_vehicles')) {
            $vehicle = ManualVehicle::query()
                ->where('geotab_device_id', $deviceId)
                ->first();
        }

        $vehiclePayload = [
            'entity' => array_filter([
                'id' => $deviceId,
                'name' => $assignment->vehicle_plate ?: null,
                'licensePlate' => $assignment->vehicle_plate ?: null,
                'comment' => trim(implode(' | ', array_filter([
                    'Client zone: '.$zone->name,
                    'Client: '.$zone->client_name,
                ]))),
            ], fn ($value): bool => $value !== null && $value !== ''),
        ];
        $vehicleSnapshot = is_array($vehicle?->geotab_snapshot ?? null) ? $vehicle->geotab_snapshot : [];

        $zonePreview = $this->buildGeotabPreviewPayload('Zone', (string) $zone->name, $zonePayload, $zone->geotab_snapshot ?? null);
        $vehiclePreview = $this->buildGeotabPreviewPayload('Device Client-Zone Assignment', (string) ($assignment->vehicle_plate ?: $deviceId), $vehiclePayload, $vehicleSnapshot);
        $payload = [
            'groupType' => 'zone_device_assignment',
            'operations' => [
                [
                    'action' => $zoneAction,
                    'entityType' => 'Zone',
                    'entityName' => (string) $zone->name,
                    'localType' => 'fleet_zone',
                    'localId' => (string) $zone->id,
                    'payload' => $zonePayload,
                    'snapshot' => is_array($zone->geotab_snapshot ?? null) ? $zone->geotab_snapshot : [],
                    'localSnapshotPayload' => $zonePayload,
                ],
                [
                    'action' => 'vehicle.update_device',
                    'entityType' => 'Device Client-Zone Assignment',
                    'entityName' => (string) ($assignment->vehicle_plate ?: $deviceId),
                    'localType' => $vehicle !== null ? 'manual_vehicle' : 'client_vehicle_assignment',
                    'localId' => $vehicle !== null ? (string) $vehicle->id : (string) $assignment->id,
                    'payload' => $vehiclePayload,
                    'snapshot' => $vehicleSnapshot,
                    'localSnapshotPayload' => $vehiclePayload,
                ],
            ],
            'assignment' => [
                'zoneName' => (string) $zone->name,
                'clientName' => (string) $zone->client_name,
                'vehiclePlate' => (string) ($assignment->vehicle_plate ?: ''),
                'deviceId' => $deviceId,
            ],
        ];

        return [
            'payload' => $payload,
            'vehicle' => $vehicle,
            'previewPayload' => $this->buildGroupedGeotabPreviewPayload(
                trim((string) $zone->name).' + '.trim((string) ($assignment->vehicle_plate ?: $deviceId)),
                $payload,
                [$zonePreview, $vehiclePreview],
            ),
        ];
    }

    private function markFleetZoneGeotabDirty(FleetZone $zone, ?string $forcedAction = null): void
    {
        $action = $forcedAction ?: ($zone->geotab_zone_id ? 'zone.update' : 'zone.create');
        $payload = $this->fleetZoneWriteBackPayload($zone, $action);
        if (
            $zone->geotab_snapshot === null
            && trim((string) $zone->geotab_zone_id) === ''
            && $zone->status !== 'deleted'
        ) {
            $zone->forceFill([
                'sync_status' => 'not_staged',
                'sync_error' => null,
                'pending_write_job_id' => null,
            ])->save();

            return;
        }
        $zone->forceFill([
            'sync_status' => $this->payloadMatchesGeotabSnapshot($payload, $zone->geotab_snapshot ?? null) ? 'synced' : 'local_modified',
            'sync_error' => null,
            'pending_write_job_id' => null,
        ])->save();
    }

    public function pushFleetZoneToGeotab(Request $request, string $zoneId): JsonResponse
    {
        $zone = $this->findFleetZone($zoneId);
        if ($zone === null) {
            return $this->respondError('Fleet zone not found.', 404);
        }

        $action = $zone->status === 'deleted' ? 'zone.remove' : ($zone->geotab_zone_id ? 'zone.update' : 'zone.create');
        $payload = $this->fleetZoneWriteBackPayload($zone, $action);
        if ($this->payloadMatchesGeotabSnapshot($payload, $zone->geotab_snapshot ?? null)) {
            return $this->respondData([
                ...$this->formatFleetZone($zone, includeDeleted: true),
                'geotabAlreadyUpToDate' => true,
                'message' => 'GeoTab is already up to date.',
            ]);
        }
        if ($this->isGeotabPreviewRequest($request)) {
            $grouped = $this->fleetZoneDeviceAssignmentWriteBackPayload($zone, $action, $payload);

            return $this->respondData([
                ...$this->formatFleetZone($zone, includeDeleted: true),
                ...$this->pendingGeotabPushMetadata('fleet_zone', (string) $zone->id),
                'message' => 'Review this GeoTab payload before staging it for approval.',
                'previewOnly' => true,
                'preview' => $grouped['payload'] ?? $payload,
                'previewPayload' => $grouped['previewPayload'] ?? $this->buildGeotabPreviewPayload('Zone', $zone->name, $payload, $zone->geotab_snapshot ?? null),
            ]);
        }

        $this->stageFleetZoneWriteBack($zone, $action, $this->geotabActorFromRequest($request));
        $this->clearFleetCaches();

        return $this->respondData([
            ...$this->formatFleetZone($zone->refresh(), includeDeleted: true),
            'message' => 'GeoTab push request staged for admin approval.',
            'preview' => $payload,
        ]);
    }

    public function zones(Request $request): JsonResponse
    {
        $localZones = $this->localFleetZones();
        $snapshot = $this->snapshot();
        $geotabZones = $this->geotabZonesForFleetEndpoint(
            $snapshot,
            $request->boolean('fresh') || empty($snapshot['zones'] ?? []),
        );

        return $this->respondData($this->mergeFleetZones($localZones, $geotabZones));
    }

    public function fleetZone(string $zoneId): JsonResponse
    {
        $zone = $this->findFleetZone($zoneId);
        if ($zone === null) {
            return $this->respondError('Fleet zone not found.', 404);
        }

        return $this->respondData($this->formatFleetZone($zone, includeDeleted: true));
    }

    public function storeFleetZone(Request $request): JsonResponse
    {
        if (! Schema::hasTable('fleet_zones')) {
            return $this->respondError('Fleet zone storage is not available. Run migrations first.', 503);
        }

        $validated = $this->validateFleetZonePayload($request);
        $points = $this->normalizedZonePoints($validated['boundaryPoints'] ?? []);
        $center = $this->zoneCenterFromPoints($points, $validated['centerLatitude'] ?? null, $validated['centerLongitude'] ?? null);
        $client = $this->fleetZoneClient($validated['clientId'] ?? null);
        $zoneName = $this->sanitizeText($validated['name'], 'Untitled zone');
        if ($this->duplicateFleetZoneExists($zoneName, $points)) {
            return $this->respondError('A zone with the same name and boundary already exists.', 409);
        }
        $zone = FleetZone::query()->create([
            'name' => $zoneName,
            'zone_type' => $this->readableZoneType($validated['zoneType'] ?? 'Custom Zone'),
            'boundary_points' => $points,
            'center_latitude' => $center['latitude'],
            'center_longitude' => $center['longitude'],
            'fleet_client_id' => $client?->id,
            'client_name' => $client?->company_name ?? $this->nullableCleanText($validated['clientName'] ?? null),
            'status' => 'active',
            'sync_status' => 'not_staged',
            'meta' => [
                'createdFrom' => 'zone_crud',
                'notes' => $this->nullableCleanText($validated['notes'] ?? null),
            ],
        ]);

        $this->clearFleetCaches();

        return $this->respondData($this->formatFleetZone($zone->refresh()));
    }

    public function updateFleetZone(Request $request, string $zoneId): JsonResponse
    {
        $zone = $this->findFleetZone($zoneId);
        if ($zone === null) {
            return $this->respondError('Fleet zone not found.', 404);
        }

        $validated = $this->validateFleetZonePayload($request, partial: true);
        $boundaryChanged = array_key_exists('boundaryPoints', $validated);
        $updates = [];
        if (array_key_exists('name', $validated)) {
            $updates['name'] = $this->sanitizeText($validated['name'], $zone->name);
        }
        if (array_key_exists('zoneType', $validated)) {
            $updates['zone_type'] = $this->readableZoneType($validated['zoneType'] ?? 'Custom Zone');
        }
        if ($boundaryChanged) {
            $points = $this->normalizedZonePoints($validated['boundaryPoints'] ?? []);
            $center = $this->zoneCenterFromPoints($points, $validated['centerLatitude'] ?? null, $validated['centerLongitude'] ?? null);
            $updates['boundary_points'] = $points;
            $updates['center_latitude'] = $center['latitude'];
            $updates['center_longitude'] = $center['longitude'];
        } elseif (array_key_exists('centerLatitude', $validated) || array_key_exists('centerLongitude', $validated)) {
            $center = $this->zoneCenterFromPoints($zone->boundary_points ?? [], $validated['centerLatitude'] ?? null, $validated['centerLongitude'] ?? null);
            $updates['center_latitude'] = $center['latitude'];
            $updates['center_longitude'] = $center['longitude'];
        }
        if (array_key_exists('clientId', $validated)) {
            $client = $this->fleetZoneClient($validated['clientId'] ?? null);
            $updates['fleet_client_id'] = $client?->id;
            $updates['client_name'] = $client?->company_name;
        }
        if (array_key_exists('clientName', $validated)) {
            $updates['client_name'] = $this->nullableCleanText($validated['clientName'] ?? null);
        }
        if (array_key_exists('notes', $validated)) {
            $meta = is_array($zone->meta) ? $zone->meta : [];
            $meta['notes'] = $this->nullableCleanText($validated['notes'] ?? null);
            $updates['meta'] = $meta;
        }

        $nextName = (string) ($updates['name'] ?? $zone->name);
        $nextPoints = (array) ($updates['boundary_points'] ?? $zone->boundary_points);
        if ($this->duplicateFleetZoneExists($nextName, $nextPoints, $zone->id)) {
            return $this->respondError('A zone with the same name and boundary already exists.', 409);
        }

        $zone->fill($updates)->save();
        $this->markFleetZoneGeotabDirty($zone->refresh());
        $this->clearFleetCaches();

        return $this->respondData($this->formatFleetZone($zone->refresh()));
    }

    public function deleteFleetZone(Request $request, string $zoneId): JsonResponse
    {
        $zone = $this->findFleetZone($zoneId);
        if ($zone === null) {
            return $this->respondError('Fleet zone not found.', 404);
        }

        $requiresGeotabRemoval = trim((string) $zone->geotab_zone_id) !== ''
            || is_array($zone->geotab_snapshot);

        if (! $requiresGeotabRemoval && $zone->pending_write_job_id !== null) {
            return $this->respondError('This zone has a GeoTab push awaiting review. Cancel or reject that push before deleting the local zone.', 409);
        }

        if (! $requiresGeotabRemoval) {
            $deleted = [
                ...$this->formatFleetZone($zone, includeDeleted: true),
                'status' => 'deleted',
                'hardDeleted' => true,
                'message' => 'Local-only zone deleted.',
            ];
            $zone->delete();
            $this->clearFleetCaches();

            return $this->respondData($deleted);
        }

        $payload = $this->fleetZoneWriteBackPayload($zone, 'zone.remove');
        if ($this->isGeotabPreviewRequest($request)) {
            return $this->respondData([
                ...$this->formatFleetZone($zone, includeDeleted: true),
                ...$this->pendingGeotabPushMetadata('fleet_zone', (string) $zone->id),
                'message' => 'Review this GeoTab zone removal before staging it for approval.',
                'previewOnly' => true,
                'preview' => $payload,
                'previewPayload' => $this->buildGeotabPreviewPayload('Zone Removal', $zone->name, $payload, $zone->geotab_snapshot ?? null),
                'geotabSnapshot' => $zone->geotab_snapshot,
            ]);
        }

        if (! $request->boolean('confirmedPreview')) {
            return $this->respondError('Review and confirm the GeoTab zone removal before deleting this synced zone.', 409);
        }

        $zone->forceFill([
            'status' => 'deleted',
            'deleted_at' => now(),
        ])->save();

        $this->markFleetZoneGeotabDirty($zone->refresh(), 'zone.remove');
        $this->stageFleetZoneWriteBack($zone->refresh(), 'zone.remove', $this->geotabActorFromRequest($request));
        $this->clearFleetCaches();

        return $this->respondData([
            ...$this->formatFleetZone($zone->refresh(), includeDeleted: true),
            'message' => 'Zone removal staged for GeoTab approval.',
        ]);
    }

    private function duplicateFleetZoneExists(string $name, array $points, ?int $exceptId = null): bool
    {
        $key = FleetZone::dedupeKey($name, $points);

        if (Schema::hasColumn('fleet_zones', 'dedupe_key')) {
            return FleetZone::query()
                ->where('dedupe_key', $key)
                ->when($exceptId !== null, fn (Builder $query): Builder => $query->where('id', '!=', $exceptId))
                ->exists();
        }

        return FleetZone::query()
            ->where('status', '!=', 'deleted')
            ->whereNull('deleted_at')
            ->when($exceptId !== null, fn (Builder $query): Builder => $query->where('id', '!=', $exceptId))
            ->get()
            ->contains(fn (FleetZone $zone): bool => FleetZone::dedupeKey((string) $zone->name, (array) $zone->boundary_points) === $key);
    }

    public function writebackJobs(): JsonResponse
    {
        if (! $this->writeBack->tableAvailable()) {
            return $this->respondData([]);
        }

        return $this->respondData(
            GeotabWriteJob::query()
                ->latest()
                ->limit(100)
                ->get()
                ->map(fn (GeotabWriteJob $job): array => $this->formatWriteBackJob($job))
                ->values()
                ->all(),
        );
    }

    public function approveWritebackJob(Request $request, string $jobId): JsonResponse
    {
        $job = GeotabWriteJob::query()->find($jobId);
        if ($job === null) {
            return $this->respondError('GeoTab write-back job not found.', 404);
        }

        $validated = $request->validate([
            'approvedBy' => ['nullable', 'string', 'max:120'],
            'temporaryPassword' => ['nullable', 'string', 'min:8', 'max:255'],
            'processNow' => ['nullable', 'boolean'],
        ]);

        if ($this->writeBackJobRequiresTemporaryPassword($job) && trim((string) ($validated['temporaryPassword'] ?? '')) === '') {
            return $this->respondError('A temporary password is required to approve a new MyGeotab driver.', 422);
        }

        $approved = $this->writeBack->approve($job, trim((string) ($validated['approvedBy'] ?? $this->geotabActorFromRequest($request))) ?: 'admin');
        $processNow = (bool) ($validated['processNow'] ?? true);
        if ($processNow) {
            $approved = $this->writeBack->process($approved, [
                'temporaryPassword' => (string) ($validated['temporaryPassword'] ?? ''),
            ]);
        }

        return $this->respondData($this->formatWriteBackJob($approved));
    }

    public function retryWritebackJob(string $jobId): JsonResponse
    {
        $job = GeotabWriteJob::query()->find($jobId);
        if ($job === null) {
            return $this->respondError('GeoTab write-back job not found.', 404);
        }

        return $this->respondData($this->formatWriteBackJob($this->writeBack->retry($job)));
    }

    public function cancelWritebackJob(Request $request, string $jobId): JsonResponse
    {
        $job = GeotabWriteJob::query()->find($jobId);
        if ($job === null) {
            return $this->respondError('GeoTab write-back job not found.', 404);
        }

        $validated = $request->validate([
            'reason' => ['required', 'string', 'max:500'],
        ]);

        return $this->respondData(
            $this->formatWriteBackJob($this->writeBack->reject($job, (string) $validated['reason'], $this->geotabActorFromRequest($request))),
        );
    }

    public function deleteWritebackJob(string $jobId): JsonResponse
    {
        $job = GeotabWriteJob::query()->find($jobId);
        if ($job === null) {
            return $this->respondError('GeoTab write-back job not found.', 404);
        }

        if (! $this->writeBack->deleteWithoutExecution($job)) {
            return $this->respondError('Approved, processing, or completed GeoTab write-back jobs cannot be deleted.', 409);
        }

        $this->clearFleetCaches();

        return $this->respondData([
            'id' => $jobId,
            'deleted' => true,
            'message' => 'Pending GeoTab write-back job deleted. No GeoTab change was applied.',
        ]);
    }

    public function storeGeotabRoute(Request $request): JsonResponse
    {
        return $this->respondError(
            'This direct GeoTab route write-back endpoint is deprecated. Save the route locally, review the Push to GeoTab preview, then confirm staging through /api/fleet/routes/{routeId}/push-geotab.',
            410,
        );
    }

    public function assignGeotabRouteDevice(Request $request, string $routeId): JsonResponse
    {
        return $this->respondError(
            'This direct GeoTab route assignment endpoint is deprecated. Update the local route assignment, review the Push to GeoTab preview, then confirm staging through /api/fleet/routes/{routeId}/push-geotab.',
            410,
        );
    }

    public function maintenance(): JsonResponse
    {
        $snapshot = $this->snapshot();
        $workOrders = $this->mergeNativeMaintenanceWorkOrders($snapshot['maintenanceWorkOrders'] ?? []);
        $overview = $snapshot['maintenanceOverview'];
        $overview['workOrders'] = count($workOrders);

        return $this->respondData([
            'overview' => $overview,
            'alerts' => $snapshot['maintenance'],
            'faults' => $snapshot['maintenanceFaults'],
            'dvir' => $snapshot['maintenanceDvir'],
            'workOrders' => $workOrders,
            'measurements' => $snapshot['maintenanceMeasurements'],
        ]);
    }

    public function maintenanceFaults(): JsonResponse
    {
        return $this->respondData($this->snapshot()['maintenanceFaults']);
    }

    public function maintenanceDvir(): JsonResponse
    {
        return $this->respondData($this->snapshot()['maintenanceDvir']);
    }

    public function maintenanceWorkOrders(): JsonResponse
    {
        return $this->respondData(
            $this->mergeNativeMaintenanceWorkOrders($this->snapshot()['maintenanceWorkOrders'] ?? [])
        );
    }

    public function fuel(Request $request): JsonResponse
    {
        return $this->respondData(
            $this->filterFuelPayloadByVehicle(
                $this->mergeNativeFuelEvents($this->snapshot()['fuel']),
                (string) $request->query('vehicle', ''),
            )
        );
    }

    public function fuelTransactions(Request $request): JsonResponse
    {
        $fuel = $this->filterFuelPayloadByVehicle(
            $this->mergeNativeFuelEvents($this->snapshot()['fuel']),
            (string) $request->query('vehicle', ''),
        );

        return $this->respondData($fuel['normalizedEvents'] ?? $fuel['transactions'] ?? []);
    }

    public function storeManualFuelEvent(Request $request): JsonResponse
    {
        if (! $this->fuelEventTableAvailable()) {
            return $this->respondError('Fuel event table is not available.', 503);
        }

        $fuelEvent = FuelEvent::query()->create($this->fuelEventAttributes(
            $this->validateFuelEventPayload($request),
            defaults: [
                'event_type' => 'manual_record',
                'source_type' => 'manual',
                'review_status' => 'confirmed',
                'confidence' => 'manual',
            ],
        ));
        $this->clearFleetCaches();

        return $this->respondData($this->formatFuelEvent($fuelEvent));
    }

    public function updateFuelEvent(Request $request, string $eventId): JsonResponse
    {
        if (! $this->fuelEventTableAvailable()) {
            return $this->respondError('Fuel event table is not available.', 503);
        }

        $fuelEvent = FuelEvent::query()->find($eventId);
        if ($fuelEvent === null) {
            return $this->respondError('Fuel event not found.', 404);
        }

        $fuelEvent->fill($this->fuelEventAttributes($this->validateFuelEventPayload($request, partial: true), $fuelEvent));
        $fuelEvent->save();
        $this->clearFleetCaches();

        return $this->respondData($this->formatFuelEvent($fuelEvent));
    }

    public function confirmFuelEvent(Request $request, string $eventId): JsonResponse
    {
        return $this->setFuelEventReviewStatus($request, $eventId, 'confirmed');
    }

    public function rejectFuelEvent(Request $request, string $eventId): JsonResponse
    {
        return $this->setFuelEventReviewStatus($request, $eventId, 'rejected');
    }

    public function storeFuelEventReceipt(Request $request, string $eventId): JsonResponse
    {
        if (! $this->fuelEventTableAvailable()) {
            return $this->respondError('Fuel event table is not available.', 503);
        }

        $fuelEvent = FuelEvent::query()->find($eventId);
        if ($fuelEvent === null) {
            return $this->respondError('Fuel event not found.', 404);
        }

        $validated = $request->validate([
            'fileName' => ['required', 'string', 'max:255'],
            'fileType' => ['required', 'string', 'max:120'],
            'dataUrl' => ['required', 'string', 'max:14000000'],
        ]);
        $this->validateProofDataUrl($validated['dataUrl'], 'dataUrl', requireDataUrl: true);

        $fuelEvent->fill([
            'receipt_file_name' => $this->sanitizeText($validated['fileName'], 'receipt'),
            'receipt_file_type' => $this->sanitizeText($validated['fileType'], 'application/octet-stream'),
            'receipt_file_data' => $validated['dataUrl'],
        ]);
        $fuelEvent->save();
        $this->clearFleetCaches();

        return $this->respondData($this->formatFuelEvent($fuelEvent));
    }

    public function fuelPriceSettings(): JsonResponse
    {
        return $this->respondData($this->systemSettingsPayload());
    }

    public function saveFuelPriceSettings(Request $request): JsonResponse
    {
        return $this->saveSystemSettings($request);
    }

    public function systemSettings(): JsonResponse
    {
        return $this->respondData($this->systemSettingsPayload());
    }

    public function saveSystemSettings(Request $request): JsonResponse
    {
        if (! Schema::hasTable('system_settings')) {
            return $this->respondError('System settings table is not available.', 503);
        }

        $validated = $request->validate([
            'dieselPricePerLiter' => ['nullable', 'numeric', 'min:0'],
            'gasolinePricePerLiter' => ['nullable', 'numeric', 'min:0'],
            'priceSourceLabel' => ['nullable', 'string', 'max:255'],
            'vatRatePercent' => ['nullable', 'numeric', 'min:0', 'max:100'],
            'freeDeliveryThreshold' => ['nullable', 'numeric', 'min:0'],
            'baseDeliveryChargePerKm' => ['nullable', 'numeric', 'min:0'],
            'fuelSurchargeRatePercent' => ['nullable', 'numeric', 'min:0', 'max:100'],
            'dieselPriceSourceLabel' => ['nullable', 'string', 'max:255'],
            'dieselPriceLastUpdated' => ['nullable', 'date'],
            'gasolinePriceSourceLabel' => ['nullable', 'string', 'max:255'],
            'gasolinePriceLastUpdated' => ['nullable', 'date'],
            'geotabServerUrl' => ['nullable', 'url', 'max:255'],
            'geotabUsername' => ['nullable', 'string', 'max:255'],
            'geotabDefaultGroupId' => ['nullable', 'string', 'max:120'],
            'geotabCompanyGroupId' => ['nullable', 'string', 'max:120'],
            'feedSeedWindowDays' => ['nullable', 'integer', 'min:1', 'max:365'],
            'feedSyncIntervalMinutes' => ['nullable', 'integer', 'min:1', 'max:1440'],
            'gpsTrailMaxPoints' => ['nullable', 'integer', 'min:10', 'max:5000'],
            'humidityAlertMinPercent' => ['nullable', 'numeric', 'min:0', 'max:100'],
            'humidityAlertMaxPercent' => ['nullable', 'numeric', 'min:0', 'max:100'],
            'idleTimeAlertThresholdMinutes' => ['nullable', 'integer', 'min:1', 'max:1440'],
            'maintenanceDueWarningDays' => ['nullable', 'integer', 'min:0', 'max:365'],
            'registrationExpiryWarningDays' => ['nullable', 'integer', 'min:0', 'max:365'],
            'licenseExpiryWarningDays' => ['nullable', 'integer', 'min:0', 'max:365'],
            'gpsLogRetentionDays' => ['nullable', 'integer', 'min:30', 'max:3650'],
            'rawGeotabFeedRetentionDays' => ['nullable', 'integer', 'min:1', 'max:3650'],
            'notificationHistoryRetentionDays' => ['nullable', 'integer', 'min:30', 'max:3650'],
            'auditLogRetentionDays' => ['nullable', 'integer', 'min:365', 'max:3650'],
            'depotLatitude' => ['nullable', 'numeric', 'between:-90,90'],
            'depotLongitude' => ['nullable', 'numeric', 'between:-180,180'],
            'defaultMapCenterLatitude' => ['nullable', 'numeric', 'between:-90,90'],
            'defaultMapCenterLongitude' => ['nullable', 'numeric', 'between:-180,180'],
            'actor' => ['nullable', 'string', 'max:255'],
        ]);

        if (
            array_key_exists('humidityAlertMinPercent', $validated)
            && array_key_exists('humidityAlertMaxPercent', $validated)
            && (float) $validated['humidityAlertMinPercent'] > (float) $validated['humidityAlertMaxPercent']
        ) {
            return $this->respondError('Humidity minimum threshold cannot be greater than the maximum threshold.', 422);
        }

        $settings = SystemSetting::query()->firstOrCreate([]);
        $before = $this->systemSettingsPayload($settings);
        $updates = $this->systemSettingsUpdatesFromPayload($validated, $settings);
        if ($updates === []) {
            return $this->respondData($this->systemSettingsPayload($settings));
        }

        $actor = $this->sanitizeText($validated['actor'] ?? $request->header('X-Pioneer-User', 'system'), 'system');
        if (Schema::hasColumn('system_settings', 'audit_log')) {
            $auditLog = is_array($settings->audit_log) ? $settings->audit_log : [];
            $auditLog[] = [
                'timestamp' => now()->toIso8601String(),
                'actor' => $actor,
                'changedFields' => array_keys($updates),
                'before' => $before,
            ];
            $updates['audit_log'] = array_slice($auditLog, -100);
        }

        $settings->fill($updates)->save();

        $this->clearFleetCaches();
        Cache::forget(self::DASHBOARD_SUMMARY_KEY);

        return $this->respondData($this->systemSettingsPayload($settings->refresh()));
    }

    public function energyCharges(): JsonResponse
    {
        return $this->respondData($this->snapshot()['fuel']['chargeEvents']);
    }

    public function compliance(): JsonResponse
    {
        return $this->respondData($this->snapshot()['compliance']);
    }

    public function notifications(): JsonResponse
    {
        return $this->respondData($this->notificationPayload());
    }

    public function markNotificationRead(string $notificationId): JsonResponse
    {
        $state = $this->notificationState();
        $state['read'][$notificationId] = true;
        $this->storeNotificationState($state);
        if ($this->notificationHistoryTableAvailable()) {
            NotificationHistory::query()
                ->where('notification_id', $notificationId)
                ->whereNull('read_at')
                ->update(['read_at' => now()]);
        }

        return $this->respondData(['id' => $notificationId, 'isRead' => true]);
    }

    public function markAllNotificationsRead(): JsonResponse
    {
        $notifications = $this->notificationPayload();
        $state = $this->notificationState();

        foreach ($notifications as $notification) {
            $id = (string) ($notification['id'] ?? '');
            if ($id !== '') {
                $state['read'][$id] = true;
            }
        }

        $this->storeNotificationState($state);
        if ($this->notificationHistoryTableAvailable()) {
            NotificationHistory::query()->whereNull('read_at')->update(['read_at' => now()]);
        }

        return $this->respondData(['updated' => count($notifications)]);
    }

    public function deleteNotification(string $notificationId): JsonResponse
    {
        $state = $this->notificationState();
        $state['deleted'][$notificationId] = now()->toIso8601String();
        $this->storeNotificationState($state);
        if ($this->notificationHistoryTableAvailable()) {
            NotificationHistory::query()
                ->where('notification_id', $notificationId)
                ->delete();
        }

        return $this->respondData(['id' => $notificationId, 'deleted' => true]);
    }

    public function clearNotifications(): JsonResponse
    {
        $notifications = $this->notificationPayload();
        $state = $this->notificationState();

        foreach ($notifications as $notification) {
            $id = (string) ($notification['id'] ?? '');
            if ($id !== '') {
                $state['deleted'][$id] = now()->toIso8601String();
            }
        }

        $this->storeNotificationState($state);
        if ($this->notificationHistoryTableAvailable()) {
            NotificationHistory::query()->delete();
        }

        return $this->respondData(['cleared' => count($notifications)]);
    }

    public function unmatchedRoutes(): JsonResponse
    {
        return $this->respondData($this->snapshot()['reports']['unmatchedRoutes']);
    }

    public function driverCongregation(): JsonResponse
    {
        return $this->respondData($this->snapshot()['reports']['driverCongregation']);
    }

    public function vehicleSubscriptionCoverageReport(): JsonResponse
    {
        return $this->respondData($this->vehicleSubscriptionCoveragePayload());
    }

    public function billingInvoices(Request $request): JsonResponse
    {
        $snapshot = $this->billingSnapshot();
        $invoices = $this->applyInvoiceReferences($snapshot['billings']);
        $invoices = $this->filterBillingInvoices($invoices, $request);
        $overview = $this->billingOverviewForInvoices($invoices);

        return $this->respondData([
            'context' => $this->billingContextPayload(),
            'overview' => $overview,
            ...$this->withPaginatedList(['invoices' => $invoices], 'invoices'),
        ]);
    }

    public function billingInvoice(string $tripId): JsonResponse
    {
        $trip = $this->findTrip($this->billingSnapshot()['trips'] ?? [], $tripId);
        if ($trip === null) {
            return $this->respondError('Invoice lookup requires a linked trip.', 404);
        }

        return $this->respondData($this->applyInvoiceReferences([$this->itemizedInvoiceForTrip($trip)])[0]);
    }

    public function storeBillingInvoice(Request $request): JsonResponse
    {
        if (! $this->billingInvoiceReferencesTableAvailable()) {
            return $this->respondError('Billing invoice references table is not available.', 503);
        }

        $validated = $request->validate([
            'tripId' => ['required', 'string', 'max:120'],
            'status' => ['nullable', 'string', 'in:draft,rejected'],
            'overrideReason' => ['required', 'string', 'max:2000'],
            'lineItems' => ['nullable', 'array'],
            'lineItems.*.label' => ['required_with:lineItems', 'string', 'max:120'],
            'lineItems.*.amount' => ['required_with:lineItems', 'numeric', 'min:0'],
            'overrides' => ['nullable', 'array'],
            'invoiceNumber' => ['nullable', 'string', 'max:255'],
            'erpReference' => ['nullable', 'string', 'max:255'],
            'poNumber' => ['nullable', 'string', 'max:255'],
            'drNumber' => ['nullable', 'string', 'max:255'],
            'notes' => ['nullable', 'string', 'max:2000'],
            'rejectionReason' => ['nullable', 'string', 'max:2000'],
            'actor' => ['nullable', 'string', 'max:120'],
        ]);

        $trip = $this->findTrip($this->billingSnapshot()['trips'] ?? [], (string) $validated['tripId']);
        if ($trip === null) {
            return $this->respondError('Invoice creation requires a linked trip.', 422);
        }

        $invoice = $this->itemizedInvoiceForTrip($trip);
        $status = strtolower((string) ($validated['status'] ?? 'draft'));
        $gate = $this->validateInvoiceStatusRequirements($request, $trip, $invoice, $status, $validated);
        if ($gate instanceof JsonResponse) {
            return $gate;
        }

        $existingReference = BillingInvoiceReference::query()
            ->where('trip_id', (string) $validated['tripId'])
            ->first();
        $currentStatus = $existingReference instanceof BillingInvoiceReference
            ? strtolower((string) ($existingReference->status ?: 'draft'))
            : null;
        if (in_array($currentStatus, ['paid', 'voided'], true)) {
            return $this->respondError('Paid or voided invoices cannot be replaced by a manual invoice.', 423);
        }
        $history = is_array($existingReference?->status_history) ? $existingReference->status_history : [];
        $meta = $this->invoiceMetaForStatus(
            $status,
            $validated,
            is_array($existingReference?->meta) ? $existingReference->meta : [],
            $request,
        );
        $reference = BillingInvoiceReference::query()->updateOrCreate(
            ['trip_id' => (string) $validated['tripId']],
            [
                'invoice_number' => $this->nullableCleanText($validated['invoiceNumber'] ?? $invoice['invoiceNumber'] ?? null),
                'erp_reference' => $this->nullableCleanText($validated['erpReference'] ?? null),
                'po_number' => $this->nullableCleanText($validated['poNumber'] ?? null),
                'dr_number' => $this->nullableCleanText($validated['drNumber'] ?? null),
                'notes' => $this->nullableCleanText($validated['notes'] ?? null),
                'status' => $status,
                'manual_invoice' => true,
                'override_reason' => $this->nullableCleanText($validated['overrideReason'] ?? null),
                'line_items' => $this->normalizedInvoiceLineItems($validated['lineItems'] ?? []),
                'overrides' => $validated['overrides'] ?? [],
                'status_history' => $this->appendInvoiceStatusHistory(
                    $history,
                    $currentStatus,
                    $status,
                    $this->invoiceLifecycleNote($status, $validated, $currentStatus === null ? 'manual invoice created' : 'manual invoice updated'),
                    $this->invoiceActorFromRequest($request),
                    ['manualInvoice' => true],
                ),
                'meta' => $meta,
            ],
        );

        $this->clearFleetCaches();
        Log::channel('billing')->info('pioneerpath.billing.invoice_created', [
            'tripId' => (string) $validated['tripId'],
            'invoiceNumber' => $reference->invoice_number,
            'status' => $status,
            'manualInvoice' => true,
        ]);

        return $this->respondData($this->applyInvoiceReferences([$invoice])[0] + [
            'references' => $this->formatInvoiceReference($reference),
        ]);
    }

    public function recalculateInvoice(string $tripId): JsonResponse
    {
        $snapshot = $this->billingSnapshot();
        $trip = $this->findTrip($snapshot['trips'] ?? [], $tripId);
        if ($trip === null) {
            return $this->respondError('Trip not found for invoice recalculation.', 404);
        }

        $before = $this->applyInvoiceReferences([$this->itemizedInvoiceForTrip($trip)])[0];
        $after = $this->applyInvoiceReferences([$this->itemizedInvoiceForTrip($trip, true)])[0];

        return $this->respondData([
            ...$after,
            'before' => [
                'subtotalBeforeVat' => $before['subtotalBeforeVat'] ?? null,
                'vat' => $before['vat'] ?? null,
                'totalWithVat' => $before['totalWithVat'] ?? $before['amount'] ?? null,
            ],
            'after' => [
                'subtotalBeforeVat' => $after['subtotalBeforeVat'] ?? null,
                'vat' => $after['vat'] ?? null,
                'totalWithVat' => $after['totalWithVat'] ?? $after['amount'] ?? null,
            ],
            'requiresConfirmation' => true,
        ]);
    }

    public function billingPreview(string $tripId): JsonResponse
    {
        $snapshot = $this->billingSnapshot();
        $trip = $this->findTrip($snapshot['trips'] ?? [], $tripId);
        if ($trip === null) {
            return $this->respondError('Trip not found for billing preview.', 404);
        }

        if (! $this->tripBillableForEstimate($trip)) {
            return $this->respondError('Trip does not have enough billing information yet.', 422);
        }

        return $this->respondData($this->applyInvoiceReferences([
            $this->itemizedInvoiceForTrip($trip, false, is_array($snapshot['fuel'] ?? null) ? $snapshot['fuel'] : []),
        ])[0]);
    }

    public function saveTripManifest(Request $request, string $tripId): JsonResponse
    {
        $validated = $request->validate([
            'cargoDescription' => ['nullable', 'string', 'max:500'],
            'packageCount' => ['nullable', 'numeric', 'min:0', 'max:100000'],
            'declaredValue' => ['nullable', 'numeric', 'min:0'],
            'referenceNumber' => ['nullable', 'string', 'max:255'],
            'poNumber' => ['nullable', 'string', 'max:255'],
            'drNumber' => ['nullable', 'string', 'max:255'],
            'siNumber' => ['nullable', 'string', 'max:255'],
            'notes' => ['nullable', 'string', 'max:2000'],
        ]);

        $manifest = [
            'cargoDescription' => $this->sanitizeText($validated['cargoDescription'] ?? '', ''),
            'packageCount' => array_key_exists('packageCount', $validated) ? (float) $validated['packageCount'] : null,
            'declaredValue' => array_key_exists('declaredValue', $validated) ? (float) $validated['declaredValue'] : null,
            'referenceNumber' => $this->nullableCleanText($validated['referenceNumber'] ?? null),
            'poNumber' => $this->nullableCleanText($validated['poNumber'] ?? null),
            'drNumber' => $this->nullableCleanText($validated['drNumber'] ?? null),
            'siNumber' => $this->nullableCleanText($validated['siNumber'] ?? null),
            'notes' => $this->nullableCleanText($validated['notes'] ?? null),
            'scope' => 'delivery_reference_only',
            'updatedAt' => now()->toIso8601String(),
        ];

        $state = $this->workflowState();
        if (isset($state['customTrips'][$tripId]) && is_array($state['customTrips'][$tripId])) {
            $state['customTrips'][$tripId]['manifest'] = $manifest;
            foreach (['cargoDescription', 'packageCount', 'declaredValue', 'referenceNumber', 'poNumber', 'drNumber', 'siNumber'] as $key) {
                if ($manifest[$key] !== null && $manifest[$key] !== '') {
                    $state['customTrips'][$tripId][$key] = $manifest[$key];
                }
            }
        } else {
            $state['tripOverrides'][$tripId] = [
                ...(is_array($state['tripOverrides'][$tripId] ?? null) ? $state['tripOverrides'][$tripId] : []),
                'manifest' => $manifest,
            ];
        }

        $this->storeWorkflowState($state);
        $this->clearFleetCaches();
        $this->syncAutomatedBillingForTripId($tripId, 'manifest updated');

        return $this->respondData([
            'tripId' => $tripId,
            'manifest' => $manifest,
        ]);
    }

    public function saveBillingInvoiceToll(Request $request, string $tripId): JsonResponse
    {
        if (! $this->billingInvoiceReferencesTableAvailable()) {
            return $this->respondError('Billing invoice references table is not available.', 503);
        }

        $trip = $this->findTrip($this->billingSnapshot()['trips'] ?? [], $tripId);
        if ($trip === null) {
            return $this->respondError('Manual toll evidence requires a linked trip.', 422);
        }

        $validated = $request->validate([
            'amount' => ['required', 'numeric', 'min:0.01'],
            'description' => ['nullable', 'string', 'max:255'],
            'receiptReference' => ['nullable', 'string', 'max:255'],
            'source' => ['nullable', 'string', 'max:120'],
            'actor' => ['nullable', 'string', 'max:120'],
        ]);

        $reference = BillingInvoiceReference::query()->firstOrCreate(
            ['trip_id' => $tripId],
            [
                'invoice_number' => 'INV-'.substr($tripId, -6),
                'status' => 'draft',
                'status_history' => $this->appendInvoiceStatusHistory([], null, 'draft', 'invoice reference created'),
            ],
        );

        $currentStatus = strtolower((string) ($reference->status ?: 'draft'));
        if (in_array($currentStatus, ['paid', 'voided'], true)) {
            return $this->respondError('Paid or voided invoices cannot accept new toll evidence.', 423);
        }

        $meta = is_array($reference->meta) ? $reference->meta : [];
        $manualTolls = is_array($meta['manualTolls'] ?? null) ? $meta['manualTolls'] : [];
        $manualTolls[] = [
            'amount' => round((float) $validated['amount'], 2),
            'description' => $this->sanitizeText($validated['description'] ?? 'Manual toll charge', 'Manual toll charge'),
            'receiptReference' => $this->nullableCleanText($validated['receiptReference'] ?? null),
            'source' => $this->sanitizeText($validated['source'] ?? 'manual', 'manual'),
            'actor' => $this->invoiceActorFromRequest($request),
            'recordedAt' => now()->toIso8601String(),
        ];
        $meta['manualTolls'] = $manualTolls;
        $meta['lastManualTollAt'] = now()->toIso8601String();

        $reference->fill([
            'meta' => $meta,
            'status_history' => $this->appendInvoiceStatusHistory(
                is_array($reference->status_history) ? $reference->status_history : [],
                $currentStatus,
                $currentStatus,
                'manual toll evidence added',
                $this->invoiceActorFromRequest($request),
                ['manualToll' => true],
            ),
        ])->save();

        $this->clearFleetCaches();
        $this->syncAutomatedBillingForTrip($trip, 'manual toll added');

        return $this->respondData($this->applyInvoiceReferences([$this->itemizedInvoiceForTrip($trip, true)])[0]);
    }

    public function updateBillingInvoice(Request $request, string $tripId): JsonResponse
    {
        if (! $this->billingInvoiceReferencesTableAvailable()) {
            return $this->respondError('Billing invoice references table is not available.', 503);
        }

        $trip = $this->findTrip($this->billingSnapshot()['trips'] ?? [], $tripId);
        if ($trip === null) {
            return $this->respondError('Invoice updates require a linked trip.', 422);
        }

        $reference = BillingInvoiceReference::query()->firstOrCreate(
            ['trip_id' => $tripId],
            [
                'invoice_number' => 'INV-'.substr($tripId, -6),
                'status' => 'draft',
                'status_history' => $this->appendInvoiceStatusHistory([], null, 'draft', 'invoice reference created'),
            ],
        );

        $validated = $request->validate([
            'status' => ['nullable', 'string', 'in:draft,approved,rejected,issued,paid,overdue'],
            'lineItems' => ['nullable', 'array'],
            'lineItems.*.label' => ['required_with:lineItems', 'string', 'max:120'],
            'lineItems.*.amount' => ['required_with:lineItems', 'numeric', 'min:0'],
            'overrides' => ['nullable', 'array'],
            'overrideReason' => ['nullable', 'string', 'max:2000'],
            'invoiceNumber' => ['nullable', 'string', 'max:255'],
            'erpReference' => ['nullable', 'string', 'max:255'],
            'poNumber' => ['nullable', 'string', 'max:255'],
            'drNumber' => ['nullable', 'string', 'max:255'],
            'notes' => ['nullable', 'string', 'max:2000'],
            'approvalNote' => ['nullable', 'string', 'max:2000'],
            'rejectionReason' => ['nullable', 'string', 'max:2000'],
            'paymentReference' => ['nullable', 'string', 'max:255'],
            'paymentDate' => ['nullable', 'date'],
            'finalChargeBasis' => ['nullable', 'string', 'max:2000'],
            'actor' => ['nullable', 'string', 'max:120'],
        ]);

        $currentStatus = strtolower((string) ($reference->status ?: 'draft'));
        if ($currentStatus === 'voided') {
            return $this->respondError('Voided invoices are locked except for statement display.', 423);
        }
        $hasFinancialChange = array_key_exists('lineItems', $validated) || array_key_exists('overrides', $validated);
        if ($currentStatus === 'paid' && $hasFinancialChange) {
            return $this->respondError('Paid invoices are read-only except ERP reference fields.', 423);
        }
        if ($hasFinancialChange && trim((string) ($validated['overrideReason'] ?? $reference->override_reason ?? '')) === '') {
            return $this->respondError('Override reason is required when changing invoice line items or computed fields.', 422);
        }

        $nextStatus = isset($validated['status']) ? strtolower((string) $validated['status']) : null;
        if ($nextStatus !== null && $nextStatus !== $currentStatus && ! $this->validInvoiceStatusTransition($currentStatus, $nextStatus)) {
            return $this->respondError('Invalid invoice status transition.', 422);
        }

        $invoice = $this->itemizedInvoiceForTrip($trip);
        if ($nextStatus !== null) {
            $gate = $this->validateInvoiceStatusRequirements($request, $trip, $invoice, $nextStatus, $validated);
            if ($gate instanceof JsonResponse) {
                return $gate;
            }
        }

        $updates = [
            'invoice_number' => array_key_exists('invoiceNumber', $validated) ? $this->nullableCleanText($validated['invoiceNumber']) : $reference->invoice_number,
            'erp_reference' => array_key_exists('erpReference', $validated) ? $this->nullableCleanText($validated['erpReference']) : $reference->erp_reference,
            'po_number' => array_key_exists('poNumber', $validated) ? $this->nullableCleanText($validated['poNumber']) : $reference->po_number,
            'dr_number' => array_key_exists('drNumber', $validated) ? $this->nullableCleanText($validated['drNumber']) : $reference->dr_number,
            'notes' => array_key_exists('notes', $validated) ? $this->nullableCleanText($validated['notes']) : $reference->notes,
        ];

        if ($hasFinancialChange) {
            $updates['manual_invoice'] = true;
            $updates['override_reason'] = $this->nullableCleanText($validated['overrideReason'] ?? $reference->override_reason);
            if (array_key_exists('lineItems', $validated)) {
                $updates['line_items'] = $this->normalizedInvoiceLineItems($validated['lineItems'] ?? []);
            }
            if (array_key_exists('overrides', $validated)) {
                $updates['overrides'] = $validated['overrides'] ?? [];
            }
        }

        if ($nextStatus !== null && $nextStatus !== $currentStatus) {
            $updates['status'] = $nextStatus;
            $updates['meta'] = $this->invoiceMetaForStatus(
                $nextStatus,
                $validated,
                is_array($reference->meta) ? $reference->meta : [],
                $request,
            );
            $updates['status_history'] = $this->appendInvoiceStatusHistory(
                is_array($reference->status_history) ? $reference->status_history : [],
                $currentStatus,
                $nextStatus,
                $this->invoiceLifecycleNote($nextStatus, $validated, 'status updated'),
                $this->invoiceActorFromRequest($request),
            );
        }

        $reference->fill($updates)->save();
        $this->clearFleetCaches();
        Log::channel('billing')->info('pioneerpath.billing.invoice_updated', [
            'tripId' => $tripId,
            'status' => $reference->status,
            'financialChange' => $hasFinancialChange,
            'statusChanged' => $nextStatus !== null && $nextStatus !== $currentStatus,
        ]);

        return $this->respondData($this->applyInvoiceReferences([$invoice])[0]);
    }

    public function voidBillingInvoice(Request $request, string $tripId): JsonResponse
    {
        if (! $this->billingInvoiceReferencesTableAvailable()) {
            return $this->respondError('Billing invoice references table is not available.', 503);
        }

        $validated = $request->validate([
            'reason' => ['required', 'string', 'max:2000'],
        ]);

        $trip = $this->findTrip($this->billingSnapshot()['trips'] ?? [], $tripId);
        if ($trip === null) {
            return $this->respondError('Invoice voiding requires a linked trip.', 422);
        }

        $reference = BillingInvoiceReference::query()->firstOrCreate(
            ['trip_id' => $tripId],
            [
                'invoice_number' => 'INV-'.substr($tripId, -6),
                'status' => 'draft',
                'status_history' => $this->appendInvoiceStatusHistory([], null, 'draft', 'invoice reference created'),
            ],
        );
        $currentStatus = strtolower((string) ($reference->status ?: 'draft'));
        if ($currentStatus === 'paid') {
            return $this->respondError('Paid invoices cannot be voided.', 423);
        }
        if (! in_array($currentStatus, ['draft', 'approved', 'rejected', 'issued', 'sent', 'overdue'], true)) {
            return $this->respondError('Only draft, approved, rejected, issued, or overdue invoices can be voided.', 422);
        }

        $reference->fill([
            'status' => 'voided',
            'voided_at' => now(),
            'void_reason' => $this->nullableCleanText($validated['reason']),
            'status_history' => $this->appendInvoiceStatusHistory(
                is_array($reference->status_history) ? $reference->status_history : [],
                $currentStatus,
                'voided',
                $validated['reason'],
                $this->invoiceActorFromRequest($request),
            ),
        ])->save();
        $this->clearFleetCaches();
        Log::channel('billing')->warning('pioneerpath.billing.invoice_voided', [
            'tripId' => $tripId,
            'previousStatus' => $currentStatus,
            'reason' => $this->nullableCleanText($validated['reason']),
        ]);

        $invoice = $this->itemizedInvoiceForTrip($trip);

        return $this->respondData($this->applyInvoiceReferences([$invoice])[0]);
    }

    public function saveBillingInvoiceReferences(Request $request, string $tripId): JsonResponse
    {
        if (! $this->billingInvoiceReferencesTableAvailable()) {
            return $this->respondError('Billing invoice references table is not available.', 503);
        }

        $validated = $request->validate([
            'invoiceNumber' => ['nullable', 'string', 'max:255'],
            'erpReference' => ['nullable', 'string', 'max:255'],
            'poNumber' => ['nullable', 'string', 'max:255'],
            'drNumber' => ['nullable', 'string', 'max:255'],
            'notes' => ['nullable', 'string', 'max:2000'],
        ]);

        if ($this->findTrip($this->billingSnapshot()['trips'] ?? [], $tripId) === null) {
            return $this->respondError('Invoice references require a linked trip.', 422);
        }

        $reference = BillingInvoiceReference::query()->updateOrCreate(
            ['trip_id' => $tripId],
            [
                'invoice_number' => $this->nullableCleanText($validated['invoiceNumber'] ?? null),
                'erp_reference' => $this->nullableCleanText($validated['erpReference'] ?? null),
                'po_number' => $this->nullableCleanText($validated['poNumber'] ?? null),
                'dr_number' => $this->nullableCleanText($validated['drNumber'] ?? null),
                'notes' => $this->nullableCleanText($validated['notes'] ?? null),
            ],
        );

        $this->clearFleetCaches();
        Log::channel('billing')->info('pioneerpath.billing.references_saved', [
            'tripId' => $tripId,
            'invoiceNumber' => $reference->invoice_number,
            'hasErpReference' => trim((string) $reference->erp_reference) !== '',
            'hasPoNumber' => trim((string) $reference->po_number) !== '',
            'hasDrNumber' => trim((string) $reference->dr_number) !== '',
        ]);

        return $this->respondData($this->formatInvoiceReference($reference));
    }

    public function billingSoa(): JsonResponse
    {
        $snapshot = $this->billingSnapshot();

        return $this->respondData($this->buildStatementOfAccounts($this->applyInvoiceReferences($snapshot['billings'] ?? [])));
    }

    public function telemetry(): JsonResponse
    {
        return $this->respondData($this->snapshot()['telemetry']);
    }

    public function telemetryAssets(): JsonResponse
    {
        return $this->respondData($this->snapshot()['telemetry']['assets']);
    }

    public function telemetryAsset(string $geotabId): JsonResponse
    {
        $timing = $this->startEndpointTiming('/fleet/telemetry/assets/{geotabId}', [
            'geotabId' => $geotabId,
        ]);
        $classification = null;
        $stage = 'snapshot';

        try {
            $snapshot = $this->snapshot();
            $stage = 'asset_lookup';
            $snapshotState = $this->snapshotState($snapshot);
            $telemetryAssets = is_array(data_get($snapshot, 'telemetry.assets')) ? data_get($snapshot, 'telemetry.assets') : [];
            $asset = collect($telemetryAssets)->firstWhere('geotabId', $geotabId);

            $this->timingLog('telemetry_asset.snapshot', [
                'geotabId' => $geotabId,
                'snapshotState' => $snapshotState,
                'telemetryAssetCount' => count($telemetryAssets),
                'assetFound' => $asset !== null,
            ]);

            if ($asset === null) {
                $classification = 'asset_missing_after_snapshot';
                $this->timingLog('telemetry_asset.result', [
                    'geotabId' => $geotabId,
                    'snapshotState' => $snapshotState,
                    'classification' => $classification,
                ]);

                $response = $this->respondError('Telemetry asset not found.', 404);
                $this->finishEndpointTiming($timing, 'error', [
                    'httpStatus' => 404,
                    'classification' => $classification,
                ]);

                return $response;
            }

            $definitions = $this->diagnosticDefinitions();
            $resolved = $this->resolvedDiagnostics();
            $stage = 'history';
            $historyStarted = hrtime(true);
            $historyException = null;
            $history = $this->safeGet(function () use ($geotabId, $resolved, &$historyException) {
                try {
                    return $this->geotab->getStatusHistory(
                        $geotabId,
                        $resolved,
                        now()->subHours(24),
                        now(),
                        48,
                    );
                } catch (\Throwable $e) {
                    $historyException = $e;
                    throw $e;
                }
            }, [
                'stage' => 'telemetry_asset_history',
                'geotabId' => $geotabId,
                'classification' => 'asset_found_history_exception_swallowed',
            ]);
            $historyElapsedMs = $this->elapsedMs($historyStarted);
            if ($historyException instanceof \Throwable) {
                $classification = 'asset_found_history_exception_swallowed';
            } elseif ($this->historyHasRows($history)) {
                $classification = 'asset_found_history_ok';
            } else {
                $classification = 'asset_found_history_empty';
            }

            $this->timingLog('telemetry_asset.history', [
                'geotabId' => $geotabId,
                'elapsedMs' => $historyElapsedMs,
                'snapshotState' => $snapshotState,
                'classification' => $classification,
                'errorKind' => $this->classifyThrowable($historyException),
                'errorType' => $historyException ? get_class($historyException) : null,
                'errorMessage' => $historyException?->getMessage(),
            ]);

            $historyPayload = [];
            foreach ($definitions as $alias => $definition) {
                $rows = $history[$alias] ?? [];
                $historyPayload[$alias] = array_values(array_map(function (array $row) use ($definition): array {
                    $value = $this->normalizeDiagnosticValue((string) ($definition['type'] ?? ''), data_get($row, 'data'));

                    return [
                        'value' => $value,
                        'displayValue' => $value === null
                            ? 'Unavailable'
                            : $this->formatDiagnosticValue($value, (string) ($definition['unit'] ?? '')),
                        'timestamp' => data_get($row, 'dateTime'),
                    ];
                }, $rows));
            }

            $assetDiagnostics = $this->mergeTelemetryWithHistory(
                is_array($asset['diagnostics'] ?? null) ? $asset['diagnostics'] : $this->emptyTelemetryEntry($definitions),
                $history,
                $definitions,
            );

            $response = $this->respondData([
                ...$asset,
                'diagnostics' => $assetDiagnostics,
                'history' => $historyPayload,
                'zones' => $snapshot['zones'],
                'routes' => $snapshot['routes'],
            ]);

            $this->finishEndpointTiming($timing, 'success', [
                'httpStatus' => 200,
                'snapshotState' => $snapshotState,
                'classification' => $classification,
            ]);

            return $response;
        } catch (\Throwable $e) {
            $classification ??= $stage === 'snapshot' ? 'snapshot_exception' : 'php_exception';
            $this->timingLog('telemetry_asset.exception', [
                'geotabId' => $geotabId,
                'classification' => $classification,
                'errorKind' => $this->classifyThrowable($e),
                'errorType' => get_class($e),
                'errorMessage' => $e->getMessage(),
            ]);

            if ($e instanceof GeotabEntityTypeMismatchException || $this->isGeotabEntityTypeMismatch($e)) {
                $response = $this->respondError(
                    'Geotab entity type mismatch: '.$e->getMessage(),
                    502,
                );
                $this->finishEndpointTiming($timing, 'error', [
                    'httpStatus' => 502,
                    'classification' => 'geotab_entity_type_mismatch',
                    'errorType' => get_class($e),
                    'errorMessage' => $e->getMessage(),
                ]);

                return $response;
            }

            $this->finishEndpointTiming($timing, 'exception', [
                'httpStatus' => 500,
                'classification' => $classification,
                'errorType' => get_class($e),
                'errorMessage' => $e->getMessage(),
            ]);

            throw $e;
        }
    }

    public function temperature(): JsonResponse
    {
        return $this->respondData($this->snapshot()['temperature']);
    }

    public function clientTracking(Request $request, string $tripId): JsonResponse
    {
        $snapshot = $this->snapshot();
        $trip = $this->findTrip($snapshot['trips'], $tripId);
        if ($trip === null) {
            return $this->respondError('Trip not found.', 404);
        }
        if (! $this->canAccessTripLocationHistory($request, $trip)) {
            return $this->respondError('Your role is not allowed to access this trip tracker.', 403);
        }

        $vehicle = $this->findVehicleForTrip($snapshot['vehicles'], $trip);
        $liveVehicle = $vehicle;
        $isCompleted = strtolower((string) ($trip['status'] ?? '')) === 'completed';
        if (! $isCompleted) {
            $live = $this->liveSnapshot();
            $liveVehicle = $this->findVehicleForTrip(
                is_array($live['vehicles'] ?? null) ? $live['vehicles'] : [],
                $trip,
            ) ?? $vehicle;
        }

        $pod = $this->loadPod($tripId);
        $assignment = $this->clientAssignmentFor($trip, $vehicle);
        $deviceId = trim((string) ($trip['deviceGeotabId'] ?? $liveVehicle['geotabId'] ?? ''));
        $start = $this->parseDate($trip['startedAt'] ?? null);
        $end = $this->parseDate($trip['endedAt'] ?? null);
        $localTrail = $this->gpsTrailForTripWithSource($trip, $deviceId, $start, $end);
        $route = $localTrail['points'];
        $gpsTrailMaxPoints = max(10, (int) $this->systemSettingsValue('gps_trail_max_points', 200));
        if (count($route) > $gpsTrailMaxPoints) {
            $route = array_slice($route, -$gpsTrailMaxPoints);
        }
        $routeSource = $localTrail['source'];

        if (count($route) < 2 && $deviceId !== '') {
            $logs = $this->safeGet(fn () => $this->geotab->getGpsTrail(
                $deviceId,
                400,
                $start?->copy()->subMinutes(3),
                ($end ?? now())->copy()->addMinutes(3),
            ));
            $this->persistGpsTrailForTrip($logs, $trip, $deviceId);
            $fallbackTrail = $this->formatTrailPoints($logs);
            if (count($fallbackTrail) > $gpsTrailMaxPoints) {
                $fallbackTrail = array_slice($fallbackTrail, -$gpsTrailMaxPoints);
            }
            if (count($fallbackTrail) >= count($route)) {
                $route = $fallbackTrail;
                $routeSource = $route === [] ? $routeSource : 'geotab_get_logrecord';
            }
        }

        $routeStops = is_array($trip['routedPlaces'] ?? null) ? $this->sanitizeRouteStops($trip['routedPlaces']) : [];
        $plannedPath = $this->plannedPathFromStops($routeStops);
        $currentCoordinate = $this->coordinateParts($liveVehicle ?? null);
        if ($currentCoordinate === null && $route !== []) {
            $currentCoordinate = $this->coordinateParts(end($route));
        }
        $destinationCoordinate = $this->coordinateParts($trip['stopPoint'] ?? null);
        if ($destinationCoordinate === null && $plannedPath !== []) {
            $destinationCoordinate = $this->coordinateParts(end($plannedPath));
        }
        $roadEta = $isCompleted
            ? ['eta' => 'Arrived', 'source' => 'completed_trip']
            : $this->googleMaps->distanceMatrixEta((string) ($trip['tripId'] ?? $tripId), $currentCoordinate ?? [], $destinationCoordinate ?? []);

        return $this->respondData($this->privacyFilteredTripForRequest($request, [
            'tripId' => $trip['tripId'],
            'status' => $trip['status'],
            'vehicle' => $trip['vehicle'],
            'driver' => $trip['driver'],
            'driverContactMasked' => $this->maskedDriverContactForClientTracking((string) ($trip['driver'] ?? '')),
            'origin' => $this->sanitizeText($trip['origin'] ?? '', 'Trip start'),
            'destination' => $this->sanitizeText($trip['destination'] ?? '', 'Trip stop'),
            'customer' => $this->sanitizeText($trip['customer'] ?? '', 'Geotab Trip'),
            'cargoType' => $this->sanitizeText($trip['cargoType'] ?? '', ''),
            'totalWeightKg' => isset($trip['totalWeightKg']) ? round((float) $trip['totalWeightKg'], 2) : null,
            'progressPercent' => $this->trackingProgress($trip['status'] ?? ''),
            'eta' => $roadEta['eta'] ?? null,
            'etaSource' => $roadEta['source'] ?? 'unavailable',
            'etaDistance' => $roadEta['distanceText'] ?? null,
            'etaDurationSeconds' => $roadEta['durationSeconds'] ?? null,
            'lastUpdated' => $liveVehicle['lastUpdated'] ?? $vehicle['lastUpdated'] ?? $snapshot['lastSyncedAt'],
            'scheduledDepartureAt' => $trip['scheduledDepartureAt'] ?? null,
            'startedAt' => $trip['startedAt'] ?? null,
            'endedAt' => $trip['endedAt'] ?? null,
            'date' => $trip['date'] ?? null,
            'isLive' => ! $isCompleted,
            'pollIntervalSeconds' => $isCompleted ? null : 30,
            'routeName' => $this->sanitizeText($trip['routeName'] ?? '', ''),
            'routedPlaces' => $routeStops,
            'route' => $route,
            'routeAvailable' => count($route) >= 2,
            'gpsPointCount' => count($route),
            'routeSource' => $routeSource,
            'routeMessage' => $this->routeMessageForPointCount(count($route)),
            'plannedPath' => $plannedPath,
            'geofences' => $this->plannedGeofencesFromStops($routeStops),
            'currentZone' => $trip['currentZone'] ?? null,
            'destinationZone' => $trip['destinationZone'] ?? null,
            'arrivalState' => $trip['arrivalState'] ?? null,
            'geofence' => [
                'matchedZone' => $trip['currentZone'] ?? null,
                'arrivedAtDestination' => $trip['arrivedAtDestination'] ?? false,
            ],
            'location' => [
                'latitude' => $liveVehicle['latitude'] ?? null,
                'longitude' => $liveVehicle['longitude'] ?? null,
                'speed' => $liveVehicle['speed'] ?? null,
                'bearing' => $liveVehicle['bearing'] ?? null,
            ],
            'assignment' => $assignment,
            'proofOfDelivery' => $pod,
            'invoiceSummary' => $this->clientSafeInvoiceSummaryForTrip($trip),
            'workflowPhase' => $trip['workflowPhase'] ?? null,
            'workflowPhaseLabel' => $trip['workflowPhaseLabel'] ?? null,
            'workflowPhaseNumber' => $trip['workflowPhaseNumber'] ?? null,
            'workflowGroup' => $trip['workflowGroup'] ?? null,
            'workflowNextAction' => $trip['workflowNextAction'] ?? null,
            'clientWorkflowStatus' => $trip['clientWorkflowStatus'] ?? null,
            'clientWorkflowMilestone' => $trip['clientWorkflowMilestone'] ?? null,
            'workflowSteps' => $trip['workflowSteps'] ?? [],
            'fulfillmentMethod' => $trip['fulfillmentMethod'] ?? null,
            'fulfillmentLabel' => $trip['fulfillmentLabel'] ?? null,
        ]));
    }

    public function storePod(Request $request, string $tripId): JsonResponse
    {
        $validated = $request->validate([
            'recipientName' => ['nullable', 'string', 'max:255'],
            'notes' => ['nullable', 'string', 'max:5000'],
            'signatureDataUrl' => ['nullable', 'string', 'max:14000000'],
            'signature' => ['nullable', 'string', 'max:14000000'],
            'status' => ['nullable', 'string', 'max:50'],
            'deliveredAt' => ['nullable', 'date'],
            'attachments' => ['nullable', 'array'],
            'attachments.*' => ['file', 'max:10240'],
        ]);
        $this->validateProofDataUrl($validated['signatureDataUrl'] ?? $validated['signature'] ?? null, 'signature');

        $signature = trim((string) ($validated['signatureDataUrl'] ?? $validated['signature'] ?? ''));
        $attachmentPaths = [];

        foreach ($request->file('attachments', []) as $file) {
            $this->validateUploadedProofFile($file);
            $attachmentPaths[] = $file->store('proof-of-delivery', 'local');
        }

        $record = [
            'trip_id' => $tripId,
            'tracking_token' => Str::lower(Str::random(20)),
            'recipient_name' => $validated['recipientName'] ?? null,
            'notes' => $validated['notes'] ?? null,
            'signature_data_url' => $signature !== '' ? $signature : null,
            'status' => $validated['status'] ?? 'submitted',
            'delivered_at' => isset($validated['deliveredAt'])
                ? Carbon::parse($validated['deliveredAt'])
                : now(),
            'attachments' => $attachmentPaths,
            'meta' => [
                'source' => 'api',
                'storedAt' => now()->toIso8601String(),
            ],
        ];

        if ($this->podTableAvailable()) {
            $pod = ProofOfDelivery::query()->updateOrCreate(
                ['trip_id' => $tripId],
                $record,
            );

            $this->clearFleetCaches();
            $this->storeCustomNotification(
                'trip',
                'POD Submitted For Review',
                $tripId.' has proof of delivery waiting for admin review.',
                ['tripId' => $tripId, 'url' => '/trips'],
            );
            $this->syncAutomatedBillingForTripId($tripId, 'pod submitted');

            return $this->respondData($this->formatPod($pod));
        }

        return $this->respondData([
            ...$record,
            'attachments' => array_values(array_map(
                fn (string $path, int $index): array => [
                    'path' => $path,
                    'url' => url('/api/fleet/pod/'.$tripId.'/attachments/'.$index),
                ],
                $attachmentPaths,
                array_keys($attachmentPaths),
            )),
            'stored' => false,
            'warning' => 'proof_of_deliveries table is not available yet. Run migrations to persist POD submissions.',
        ]);
    }

    public function reviewPod(Request $request, string $tripId): JsonResponse
    {
        if (! $this->podTableAvailable()) {
            return $this->respondError('Proof of delivery storage is not available.', 503);
        }

        $validated = $request->validate([
            'status' => ['required', 'string', 'in:verified,rejected'],
            'reviewNote' => ['nullable', 'string', 'max:2000'],
            'actor' => ['nullable', 'string', 'max:120'],
        ]);

        $pod = ProofOfDelivery::query()->where('trip_id', $tripId)->latest('updated_at')->first();
        if (! $pod instanceof ProofOfDelivery) {
            return $this->respondError('Proof of delivery must be submitted before admin review.', 404);
        }

        $nextStatus = strtolower((string) $validated['status']);
        $reviewNote = $this->nullableCleanText($validated['reviewNote'] ?? null);
        if ($nextStatus === 'rejected' && trim((string) $reviewNote) === '') {
            return $this->respondError('A review note is required when rejecting proof of delivery.', 422);
        }

        if ($nextStatus === 'verified' && ! filled($pod->signature_data_url) && count((array) ($pod->attachments ?? [])) === 0) {
            return $this->respondError('Proof of delivery cannot be verified without a signature or attachment.', 422);
        }

        $actor = $this->invoiceActorFromRequest($request);
        $meta = is_array($pod->meta) ? $pod->meta : [];
        $history = is_array($meta['reviewHistory'] ?? null) ? $meta['reviewHistory'] : [];
        $history[] = [
            'from' => $pod->status,
            'to' => $nextStatus,
            'note' => $reviewNote,
            'actor' => $actor,
            'at' => now()->toIso8601String(),
        ];

        $meta['reviewStatus'] = $nextStatus;
        $meta['reviewNote'] = $reviewNote;
        $meta['reviewedBy'] = $actor;
        $meta['reviewedAt'] = now()->toIso8601String();
        $meta['reviewHistory'] = array_values($history);

        $pod->fill([
            'status' => $nextStatus,
            'meta' => $meta,
        ])->save();

        $this->clearFleetCaches();
        $this->syncAutomatedBillingForTripId($tripId, $nextStatus === 'verified' ? 'pod verified by admin' : 'pod rejected by admin');
        $this->storeCustomNotification(
            $nextStatus === 'verified' ? 'billing' : 'trip',
            $nextStatus === 'verified' ? 'POD Verified - Billing Review Ready' : 'POD Rejected',
            $nextStatus === 'verified'
                ? $tripId.' is ready for accounting billing review.'
                : $tripId.' requires POD correction before billing can proceed.',
            ['tripId' => $tripId, 'url' => $nextStatus === 'verified' ? '/billing' : '/trips'],
        );

        return $this->respondData($this->formatPod($pod));
    }

    public function downloadPodAttachment(Request $request, string $tripId, int $index): StreamedResponse|JsonResponse
    {
        if (! $this->podTableAvailable()) {
            return $this->respondError('Proof of delivery storage is not available.', 503);
        }

        $pod = ProofOfDelivery::query()->where('trip_id', $tripId)->first();
        $attachments = array_values((array) ($pod?->attachments ?? []));
        $path = isset($attachments[$index]) ? $this->podAttachmentPath($attachments[$index]) : null;

        if ($pod === null || $path === null || ! Storage::disk('local')->exists($path)) {
            return $this->respondError('Proof attachment not found.', 404);
        }

        $mime = Storage::disk('local')->mimeType($path) ?: 'application/octet-stream';
        if (! in_array($mime, $this->allowedProofMimeTypes(), true)) {
            return $this->respondError('Stored proof attachment type is not allowed.', 422);
        }

        return Storage::disk('local')->download($path, basename($path), [
            'Content-Type' => $mime,
            'X-Content-Type-Options' => 'nosniff',
            'Cache-Control' => 'private, no-store',
        ]);
    }

    private function snapshot(): array
    {
        $fresh = Cache::get(self::SNAPSHOT_FRESH_KEY);
        if (is_array($fresh) && $fresh !== []) {
            $this->timingLog('snapshot.cache', [
                'freshCacheHit' => true,
                'staleCacheAvailable' => false,
                'lockAcquired' => false,
                'cacheState' => 'fresh_hit',
                'backendForceRefresh' => false,
            ]);

            return $fresh;
        }

        $stale = Cache::get(self::SNAPSHOT_STALE_KEY);
        if ($this->shouldServeCachedSnapshotOnly()) {
            if (is_array($stale) && $stale !== []) {
                $this->timingLog('snapshot.cache', [
                    'freshCacheHit' => false,
                    'staleCacheAvailable' => true,
                    'lockAcquired' => false,
                    'cacheState' => 'stale_returned_without_user_refresh',
                    'backendForceRefresh' => false,
                ]);

                return [
                    ...$stale,
                    'stale' => true,
                    'refreshing' => true,
                    'geotabAvailable' => false,
                    'geotabReason' => 'background_refresh_required',
                ];
            }

            $this->markGeotabUnavailable('snapshot_unavailable');
            $this->timingLog('snapshot.cache', [
                'freshCacheHit' => false,
                'staleCacheAvailable' => false,
                'lockAcquired' => false,
                'cacheState' => 'empty_snapshot_returned_without_user_refresh',
                'backendForceRefresh' => false,
            ]);

            return [
                ...$this->emptySnapshot(),
                'stale' => true,
                'refreshing' => true,
                'geotabAvailable' => false,
                'geotabReason' => 'snapshot_unavailable',
                'lastSyncedAt' => now()->toIso8601String(),
            ];
        }

        $lock = Cache::lock(self::SNAPSHOT_LOCK_KEY, 25);
        $lockAcquired = $lock->get();

        if ($lockAcquired) {
            if (is_array($stale) && $stale !== []) {
                optional($lock)->release();

                $this->timingLog('snapshot.cache', [
                    'freshCacheHit' => false,
                    'staleCacheAvailable' => true,
                    'lockAcquired' => true,
                    'cacheState' => 'stale_returned_scheduler_refresh',
                    'backendForceRefresh' => false,
                ]);

                return [
                    ...$stale,
                    'stale' => true,
                    'refreshing' => false,
                ];
            }

            try {
                $snapshot = $this->buildSnapshot();
                Cache::put(self::SNAPSHOT_FRESH_KEY, $snapshot, now()->addSeconds(45));
                Cache::put(self::SNAPSHOT_STALE_KEY, $snapshot, now()->addMinutes(15));
                $this->timingLog('snapshot.cache', [
                    'freshCacheHit' => false,
                    'staleCacheAvailable' => is_array($stale) && $stale !== [],
                    'lockAcquired' => true,
                    'cacheState' => 'fresh_absent',
                    'backendForceRefresh' => false,
                ]);

                return $snapshot;
            } catch (\Throwable $e) {
                if (is_array($stale) && $stale !== []) {
                    $this->timingLog('snapshot.cache', [
                        'freshCacheHit' => false,
                        'staleCacheAvailable' => true,
                        'lockAcquired' => true,
                        'cacheState' => 'stale_fallback_after_build_error',
                        'backendForceRefresh' => false,
                        'errorType' => get_class($e),
                        'errorMessage' => $e->getMessage(),
                    ]);

                    return [
                        ...$stale,
                        'stale' => true,
                        'lastError' => $e->getMessage(),
                    ];
                }

                throw $e;
            } finally {
                optional($lock)->release();
            }
        }

        if (is_array($stale) && $stale !== []) {
            $this->timingLog('snapshot.cache', [
                'freshCacheHit' => false,
                'staleCacheAvailable' => true,
                'lockAcquired' => false,
                'cacheState' => 'stale_fallback_while_locked',
                'backendForceRefresh' => false,
            ]);

            return [
                ...$stale,
                'stale' => true,
            ];
        }

        $this->timingLog('snapshot.cache', [
            'freshCacheHit' => false,
            'staleCacheAvailable' => false,
            'lockAcquired' => false,
            'cacheState' => 'empty_snapshot_returned',
            'backendForceRefresh' => false,
        ]);

        return $this->emptySnapshot();
    }

    private function liveSnapshot(): array
    {
        $fresh = Cache::get(self::LIVE_FRESH_KEY);
        if (is_array($fresh) && $fresh !== []) {
            $this->timingLog('live_snapshot.cache', [
                'freshCacheHit' => true,
                'staleCacheAvailable' => false,
                'lockAcquired' => false,
                'cacheState' => 'fresh_hit',
                'summarySeedState' => 'not_used',
                'backendForceRefresh' => false,
            ]);

            return $fresh;
        }

        $stale = Cache::get(self::LIVE_STALE_KEY);
        ['summary' => $summary, 'source' => $summarySeedSource] = $this->cachedSummarySeedWithSource();
        if ($this->shouldServeCachedSnapshotOnly()) {
            if (is_array($stale) && $stale !== []) {
                $this->timingLog('live_snapshot.cache', [
                    'freshCacheHit' => false,
                    'staleCacheAvailable' => true,
                    'lockAcquired' => false,
                    'cacheState' => 'stale_returned_without_user_refresh',
                    'summarySeedState' => $summarySeedSource,
                    'backendForceRefresh' => false,
                ]);

                return [
                    ...$stale,
                    'stale' => true,
                    'refreshing' => true,
                    'geotabAvailable' => false,
                    'geotabReason' => 'background_refresh_required',
                ];
            }

            $this->markGeotabUnavailable('live_snapshot_unavailable');
            $this->timingLog('live_snapshot.cache', [
                'freshCacheHit' => false,
                'staleCacheAvailable' => false,
                'lockAcquired' => false,
                'cacheState' => 'empty_snapshot_returned_without_user_refresh',
                'summarySeedState' => $summarySeedSource,
                'backendForceRefresh' => false,
            ]);

            return [
                'stale' => true,
                'refreshing' => true,
                'geotabAvailable' => false,
                'geotabReason' => 'live_snapshot_unavailable',
                'lastSyncedAt' => $summary['lastSyncedAt'] ?? now()->toIso8601String(),
                'movingVehicles' => 0,
                'vehicles' => [],
                'trips' => [],
            ];
        }

        $lock = Cache::lock(self::LIVE_LOCK_KEY, 10);
        $lockAcquired = $lock->get();

        if ($lockAcquired) {
            if (is_array($stale) && $stale !== []) {
                optional($lock)->release();

                $this->timingLog('live_snapshot.cache', [
                    'freshCacheHit' => false,
                    'staleCacheAvailable' => true,
                    'lockAcquired' => true,
                    'cacheState' => 'stale_returned_scheduler_refresh',
                    'summarySeedState' => $summarySeedSource,
                    'backendForceRefresh' => false,
                ]);

                return [
                    ...$stale,
                    'stale' => true,
                    'refreshing' => false,
                ];
            }

            try {
                $payload = $this->buildLiveSnapshot($summary);
                Cache::put(self::LIVE_FRESH_KEY, $payload, now()->addSeconds(5));
                Cache::put(self::LIVE_STALE_KEY, $payload, now()->addMinutes(5));
                $this->timingLog('live_snapshot.cache', [
                    'freshCacheHit' => false,
                    'staleCacheAvailable' => is_array($stale) && $stale !== [],
                    'lockAcquired' => true,
                    'cacheState' => 'fresh_absent',
                    'summarySeedState' => $summarySeedSource,
                    'backendForceRefresh' => false,
                ]);

                return $payload;
            } catch (\Throwable $e) {
                if (is_array($stale) && $stale !== []) {
                    $this->timingLog('live_snapshot.cache', [
                        'freshCacheHit' => false,
                        'staleCacheAvailable' => true,
                        'lockAcquired' => true,
                        'cacheState' => 'stale_fallback_after_build_error',
                        'summarySeedState' => $summarySeedSource,
                        'backendForceRefresh' => false,
                        'errorType' => get_class($e),
                        'errorMessage' => $e->getMessage(),
                    ]);

                    return [
                        ...$stale,
                        'stale' => true,
                        'lastError' => $e->getMessage(),
                    ];
                }

                return [
                    'stale' => true,
                    'lastSyncedAt' => $summary['lastSyncedAt'] ?? now()->toIso8601String(),
                    'movingVehicles' => 0,
                    'vehicles' => [],
                    'trips' => [],
                    'lastError' => $e->getMessage(),
                ];
            } finally {
                optional($lock)->release();
            }
        }

        if (is_array($stale) && $stale !== []) {
            $this->timingLog('live_snapshot.cache', [
                'freshCacheHit' => false,
                'staleCacheAvailable' => true,
                'lockAcquired' => false,
                'cacheState' => 'stale_fallback_while_locked',
                'summarySeedState' => $summarySeedSource,
                'backendForceRefresh' => false,
            ]);

            return [
                ...$stale,
                'stale' => true,
            ];
        }

        $this->timingLog('live_snapshot.cache', [
            'freshCacheHit' => false,
            'staleCacheAvailable' => false,
            'lockAcquired' => false,
            'cacheState' => 'empty_snapshot_returned',
            'summarySeedState' => $summarySeedSource,
            'backendForceRefresh' => false,
        ]);

        return [
            'stale' => true,
            'lastSyncedAt' => $summary['lastSyncedAt'] ?? now()->toIso8601String(),
            'movingVehicles' => 0,
            'vehicles' => [],
            'trips' => [],
        ];
    }

    public function warmSnapshotCachesForConsole(): array
    {
        if (! app()->runningInConsole()) {
            return [
                'warmed' => false,
                'reason' => 'console_only',
            ];
        }

        $snapshot = $this->buildSnapshot();
        Cache::put(self::SNAPSHOT_FRESH_KEY, $snapshot, now()->addSeconds(45));
        Cache::put(self::SNAPSHOT_STALE_KEY, $snapshot, now()->addMinutes(15));

        $live = $this->buildLiveSnapshot($snapshot);
        Cache::put(self::LIVE_FRESH_KEY, $live, now()->addSeconds(5));
        Cache::put(self::LIVE_STALE_KEY, $live, now()->addMinutes(5));

        return [
            'warmed' => true,
            'vehicles' => count($snapshot['vehicles'] ?? []),
            'trips' => count($snapshot['trips'] ?? []),
            'routes' => count($snapshot['routes'] ?? []),
            'liveVehicles' => count($live['vehicles'] ?? []),
        ];
    }

    private function shouldServeCachedSnapshotOnly(): bool
    {
        return ! app()->runningInConsole()
            || request()->is('api/*')
            || request()->is('fleet/*')
            || request()->is('vehicles/*')
            || app()->runningUnitTests()
            || app()->environment('testing');
    }

    private function cachedSummarySeed(): array
    {
        return $this->cachedSummarySeedWithSource()['summary'];
    }

    private function cachedSummarySeedWithSource(): array
    {
        $fresh = Cache::get(self::SNAPSHOT_FRESH_KEY);
        if (is_array($fresh) && $fresh !== []) {
            return [
                'summary' => $fresh,
                'source' => 'fresh_summary',
            ];
        }

        $stale = Cache::get(self::SNAPSHOT_STALE_KEY);
        if (is_array($stale) && $stale !== []) {
            return [
                'summary' => $stale,
                'source' => 'stale_summary',
            ];
        }

        return [
            'summary' => $this->emptySnapshot(),
            'source' => 'empty_summary',
        ];
    }

    private function buildLiveSnapshot(array $summary): array
    {
        $zones = is_array($summary['zones'] ?? null) ? $summary['zones'] : [];
        $definitions = $this->diagnosticDefinitions();
        $resolvedDiagnostics = $this->resolvedDiagnostics();
        $diagnosticIdToAlias = [];

        foreach ($resolvedDiagnostics as $alias => $diagnostic) {
            $diagnosticId = (string) ($diagnostic['id'] ?? '');
            if ($diagnosticId !== '') {
                $diagnosticIdToAlias[$diagnosticId] = $alias;
            }
        }

        $vehicleState = $this->loadLiveFeedState($summary);
        $vehicleState = $this->syncLiveFeedState(
            $vehicleState,
            $summary,
            $definitions,
            $resolvedDiagnostics,
            $diagnosticIdToAlias,
        );
        $this->storeLiveFeedState($vehicleState);

        $vehicles = array_values(array_map(function (array $vehicle) use ($zones): array {
            $latitude = (float) ($vehicle['latitude'] ?? 0);
            $longitude = (float) ($vehicle['longitude'] ?? 0);
            $coordinate = ['latitude' => $latitude, 'longitude' => $longitude];
            $currentZone = ($latitude !== 0.0 || $longitude !== 0.0)
                ? $this->zoneNameForCoordinate($latitude, $longitude, $zones)
                : ($vehicle['currentZone'] ?? null);
            $destinationZone = $vehicle['destinationZone'] ?? null;
            $reportedSpeed = (float) ($vehicle['speed'] ?? 0);
            $isDriving = (($vehicle['isDriving'] ?? false) === true) || $reportedSpeed > 1.0;
            $lastGeotabAt = $this->parseDate($vehicle['lastGeotabAt'] ?? $vehicle['lastUpdated'] ?? null);
            $sourceAgeMs = $lastGeotabAt?->diffInMilliseconds(now(), false);
            $sourceAgeMs = is_numeric($sourceAgeMs) && $sourceAgeMs >= 0
                ? (int) round((float) $sourceAgeMs)
                : null;
            $syncState = $sourceAgeMs !== null && $sourceAgeMs > 300000
                ? 'stale'
                : (($vehicle['syncState'] ?? 'live'));
            $ignitionOn = (($vehicle['ignitionOn'] ?? false) === true) || $isDriving;
            $motionState = $this->liveVehicleMotionState($syncState, $isDriving, $ignitionOn, $reportedSpeed);
            $routeStops = is_array($vehicle['routeStops'] ?? null) ? $vehicle['routeStops'] : [];
            $navigationTarget = $this->liveNavigationTarget($vehicle, $currentZone);
            $weather = $this->googleMaps->currentWeather($coordinate);
            $traffic = $navigationTarget !== null
                ? $this->googleMaps->trafficAwareRoute(
                    (string) ($vehicle['geotabId'] ?? $vehicle['plate'] ?? 'vehicle'),
                    $coordinate,
                    $navigationTarget['coordinate'],
                )
                : null;

            return [
                'geotabId' => $vehicle['geotabId'] ?? '',
                'name' => $vehicle['name'] ?? null,
                'plate' => $vehicle['plate'] ?? null,
                'vehicle' => $vehicle['plate'] ?? null,
                'serialNumber' => $vehicle['serialNumber'] ?? null,
                'vin' => $vehicle['vin'] ?? null,
                'deviceType' => $vehicle['deviceType'] ?? null,
                'comment' => $vehicle['comment'] ?? null,
                'truckType' => $vehicle['truckType'] ?? null,
                'vehicleType' => $vehicle['vehicleType'] ?? $vehicle['truckType'] ?? null,
                'makeModel' => $vehicle['makeModel'] ?? null,
                'cargoCapacityKg' => $vehicle['cargoCapacityKg'] ?? null,
                'registrationExpiryDate' => $vehicle['registrationExpiryDate'] ?? null,
                'insuranceExpiryDate' => $vehicle['insuranceExpiryDate'] ?? null,
                'registrationDaysRemaining' => $vehicle['registrationDaysRemaining'] ?? null,
                'insuranceDaysRemaining' => $vehicle['insuranceDaysRemaining'] ?? null,
                'year' => $vehicle['year'] ?? null,
                'fuelCapacity' => $vehicle['fuelCapacity'] ?? null,
                'fuelLevelRatio' => $vehicle['fuelLevelRatio'] ?? null,
                'fuelLevelSupported' => ($vehicle['fuelLevelSupported'] ?? false) === true,
                'odometerKm' => $vehicle['odometerKm'] ?? null,
                'mileage' => $vehicle['mileage'] ?? null,
                'engineHours' => $vehicle['engineHours'] ?? null,
                'fuelEconomyKmPerLiter' => $vehicle['fuelEconomyKmPerLiter'] ?? null,
                'diagnostics' => $vehicle['diagnostics'] ?? null,
                'driver' => $vehicle['driver'] ?? null,
                'status' => $isDriving ? 'on trip' : ($vehicle['status'] ?? 'available'),
                'motionState' => $motionState['state'],
                'motionStateLabel' => $motionState['label'],
                'ignitionState' => $ignitionOn ? 'on' : 'off',
                'isDriving' => $isDriving,
                'ignitionOn' => $ignitionOn,
                'isCommunicating' => ($vehicle['isCommunicating'] ?? false) === true,
                'speed' => (int) round($reportedSpeed),
                'bearing' => (int) round((float) ($vehicle['bearing'] ?? 0)),
                'latitude' => $latitude,
                'longitude' => $longitude,
                'lastGeotabAt' => $lastGeotabAt?->toIso8601String(),
                'lastUpdated' => $lastGeotabAt?->toIso8601String(),
                'sourceAgeMs' => $sourceAgeMs,
                'syncState' => $syncState,
                'currentZone' => $currentZone,
                'destinationZone' => $destinationZone,
                'arrivalState' => $this->arrivalState($isDriving, $currentZone, $destinationZone),
                'currentLocationLabel' => $vehicle['currentLocationLabel'] ?? $currentZone,
                'routeName' => $vehicle['routeName'] ?? $vehicle['assignedRoute'] ?? null,
                'routeStops' => $routeStops,
                'navigationTarget' => $navigationTarget,
                'weather' => $weather,
                'environment' => [
                    'weather' => $weather,
                    'temperatureC' => $weather['temperatureC'] ?? data_get($vehicle, 'diagnostics.outsideTemperature.value'),
                    'relativeHumidity' => $weather['relativeHumidity'] ?? data_get($vehicle, 'diagnostics.relativeHumidity.value'),
                    'source' => $weather['source'] ?? data_get($vehicle, 'diagnostics.outsideTemperature.source', 'vehicle_diagnostics'),
                ],
                'traffic' => $traffic !== null ? [
                    ...$traffic,
                    'targetName' => $navigationTarget['name'] ?? null,
                    'targetSequence' => $navigationTarget['sequence'] ?? null,
                    'distanceKm' => isset($traffic['distanceMeters']) && is_numeric($traffic['distanceMeters'])
                        ? round(((float) $traffic['distanceMeters']) / 1000, 1)
                        : null,
                    'delayMinutes' => isset($traffic['delaySeconds']) && is_numeric($traffic['delaySeconds'])
                        ? (int) ceil(((float) $traffic['delaySeconds']) / 60)
                        : null,
                ] : null,
                'trafficAwareness' => [
                    'configured' => $this->googleMaps->isConfigured(),
                    'available' => $traffic !== null,
                    'severity' => $traffic['severity'] ?? 'unknown',
                    'source' => $traffic['source'] ?? 'unavailable',
                ],
                'healthStatus' => $vehicle['healthStatus'] ?? 'healthy',
                'healthScore' => $vehicle['healthScore'] ?? null,
                'healthAlerts' => $vehicle['healthAlerts'] ?? [],
                'recentFaults' => $vehicle['recentFaults'] ?? [],
                'recentExceptions' => $vehicle['recentExceptions'] ?? [],
            ];
        }, $vehicleState));

        return [
            'stale' => false,
            'lastSyncedAt' => now()->toIso8601String(),
            'movingVehicles' => count(array_filter($vehicles, fn (array $vehicle): bool => ($vehicle['isDriving'] ?? false) === true)),
            'engineOnVehicles' => count(array_filter($vehicles, fn (array $vehicle): bool => ($vehicle['ignitionOn'] ?? false) === true)),
            'idleVehicles' => count(array_filter($vehicles, fn (array $vehicle): bool => ($vehicle['ignitionOn'] ?? false) === true && ($vehicle['isDriving'] ?? false) !== true)),
            'availableVehicles' => count(array_filter($vehicles, fn (array $vehicle): bool => strtolower((string) ($vehicle['status'] ?? '')) === 'available')),
            'vehicles' => $vehicles,
            'trips' => array_values(array_filter(
                is_array($summary['trips'] ?? null) ? $summary['trips'] : [],
                fn (array $trip): bool => in_array(strtolower((string) ($trip['status'] ?? '')), ['dispatched', 'in progress', 'on trip', 'pending_approval'], true),
            )),
        ];
    }

    private function liveNavigationTarget(array $vehicle, ?string $currentZone): ?array
    {
        $routeStops = is_array($vehicle['routeStops'] ?? null) ? $vehicle['routeStops'] : [];
        if ($routeStops === []) {
            return null;
        }

        $fallback = null;
        foreach ($routeStops as $index => $stop) {
            if (! is_array($stop)) {
                continue;
            }

            $coordinate = $this->coordinateParts(data_get($stop, 'center', $stop));
            if ($coordinate === null) {
                continue;
            }

            $name = $this->sanitizeText(data_get($stop, 'name', data_get($stop, 'zoneName', 'Route stop')), 'Route stop');
            $target = [
                'name' => $name,
                'sequence' => (int) data_get($stop, 'sequence', $index + 1),
                'coordinate' => $coordinate,
            ];
            $fallback = $target;

            if ($currentZone === null || trim($currentZone) === '' || strcasecmp($name, $currentZone) !== 0) {
                return $target;
            }
        }

        return $fallback;
    }

    private function liveVehicleMotionState(string $syncState, bool $isDriving, bool $ignitionOn, float $speedKph): array
    {
        if ($isDriving || $speedKph > 1.0) {
            return [
                'state' => 'moving',
                'label' => 'Moving - ignition on',
            ];
        }

        if ($ignitionOn) {
            return [
                'state' => 'idle',
                'label' => 'Idle - ignition on',
            ];
        }

        $normalizedSyncState = strtolower(trim($syncState));
        if (in_array($normalizedSyncState, ['offline_cached', 'stale'], true)) {
            return [
                'state' => $normalizedSyncState === 'offline_cached' ? 'offline' : 'stale',
                'label' => $normalizedSyncState === 'offline_cached' ? 'Offline cached' : 'Stale data',
            ];
        }

        return [
            'state' => 'ignition_off',
            'label' => 'Ignition off',
        ];
    }

    private function analyticsSummaryPayload(): array
    {
        $snapshot = $this->snapshot();
        $live = $this->liveSnapshot();
        $driverPerformance = $this->driverPerformancePayload();
        $vehicleHealth = $this->vehicleHealthPayload();
        $routeEfficiency = $this->routeEfficiencyPayload();
        $tripForecast = $this->tripForecastPayload();
        $fuelTrend = $this->fuelTrendPayload();

        return [
            'lastSyncedAt' => $snapshot['lastSyncedAt'] ?? now()->toIso8601String(),
            'dashboard' => $snapshot['dashboard'] ?? [],
            'billingOverview' => $snapshot['billingOverview'] ?? [],
            'fuel' => $snapshot['fuel'] ?? [],
            'telemetry' => $snapshot['telemetry'] ?? [],
            'temperature' => $snapshot['temperature'] ?? [],
            'reports' => $snapshot['reports'] ?? [],
            'driverPerformance' => $driverPerformance['rankedDrivers'],
            'driverPerformanceTop' => $driverPerformance['topDrivers'],
            'driverPerformanceBottom' => $driverPerformance['bottomDrivers'],
            'vehicleHealthRisk' => $vehicleHealth['vehicles'],
            'routeEfficiency' => $routeEfficiency['routes'],
            'tripVolumeForecast' => $tripForecast['forecast'],
            'fuelTrend' => $fuelTrend,
            'operations' => [
                'vehicles' => $snapshot['vehicles'] ?? [],
                'trips' => $snapshot['trips'] ?? [],
                'drivers' => $snapshot['drivers'] ?? [],
                'maintenance' => $snapshot['maintenance'] ?? [],
                'compliance' => $snapshot['compliance'] ?? [],
                'live' => [
                    'movingVehicles' => $live['movingVehicles'] ?? 0,
                    'engineOnVehicles' => $live['engineOnVehicles'] ?? 0,
                    'idleVehicles' => $live['idleVehicles'] ?? 0,
                    'availableVehicles' => $live['availableVehicles'] ?? 0,
                ],
            ],
        ];
    }

    private function maintenanceSummaryPayload(): array
    {
        $snapshot = $this->snapshot();
        $live = $this->liveSnapshot();

        return [
            'lastSyncedAt' => $snapshot['lastSyncedAt'] ?? now()->toIso8601String(),
            'overview' => $snapshot['maintenanceOverview'] ?? [],
            'alerts' => $snapshot['maintenance'] ?? [],
            'faults' => $snapshot['maintenanceFaults'] ?? [],
            'dvir' => $snapshot['maintenanceDvir'] ?? [],
            'workOrders' => $snapshot['maintenanceWorkOrders'] ?? [],
            'measurements' => $snapshot['maintenanceMeasurements'] ?? [],
            'predictive' => $this->predictiveMaintenanceRows(
                is_array($snapshot['vehicles'] ?? null) ? $snapshot['vehicles'] : [],
            ),
            'vehicles' => array_values(array_map(function (array $vehicle): array {
                $maintenanceState = strtolower((string) ($vehicle['status'] ?? ''));

                return [
                    'geotabId' => $vehicle['geotabId'] ?? '',
                    'plate' => $vehicle['plate'] ?? null,
                    'truckType' => $vehicle['truckType'] ?? null,
                    'driver' => $vehicle['driver'] ?? null,
                    'status' => $vehicle['status'] ?? null,
                    'maintenanceState' => $maintenanceState === 'maintenance' ? 'active' : 'normal',
                    'healthStatus' => $vehicle['healthStatus'] ?? 'healthy',
                    'engineHours' => data_get($vehicle, 'diagnostics.engineHours.value'),
                    'odometerKm' => data_get($vehicle, 'diagnostics.rawOdometer.value'),
                    'currentLocationLabel' => $vehicle['currentLocationLabel'] ?? null,
                ];
            }, is_array($snapshot['vehicles'] ?? null) ? $snapshot['vehicles'] : [])),
            'live' => [
                'movingVehicles' => $live['movingVehicles'] ?? 0,
                'idleVehicles' => $live['idleVehicles'] ?? 0,
            ],
        ];
    }

    private function loadLiveFeedState(array $summary): array
    {
        $seededVehicles = $this->seedLiveVehicles($summary);
        $cached = Cache::get(self::LIVE_FEED_STATE_KEY, []);
        $cachedVehicles = is_array($cached['vehicles'] ?? null) ? $cached['vehicles'] : [];

        foreach ($seededVehicles as $deviceId => $seed) {
            $cachedVehicle = $cachedVehicles[$deviceId] ?? null;
            if (is_array($cachedVehicle)) {
                $seededVehicles[$deviceId] = [...$cachedVehicle, ...$seed];
            }
        }

        foreach ($cachedVehicles as $deviceId => $vehicle) {
            if ($deviceId === '' || isset($seededVehicles[$deviceId]) || ! is_array($vehicle)) {
                continue;
            }

            $seededVehicles[$deviceId] = $vehicle;
        }

        return $seededVehicles;
    }

    private function storeLiveFeedState(array $vehicles): void
    {
        Cache::put(self::LIVE_FEED_STATE_KEY, [
            'vehicles' => $vehicles,
            'storedAt' => now()->toIso8601String(),
        ], now()->addMinutes(15));
    }

    private function seedLiveVehicles(array $summary): array
    {
        $vehicles = [];
        $summaryVehicles = is_array($summary['vehicles'] ?? null) ? $summary['vehicles'] : [];

        foreach ($summaryVehicles as $vehicle) {
            $deviceId = (string) ($vehicle['geotabId'] ?? '');
            if ($deviceId === '') {
                continue;
            }

            $vehicles[$deviceId] = [
                'geotabId' => $deviceId,
                'name' => $vehicle['name'] ?? null,
                'plate' => $vehicle['plate'] ?? null,
                'serialNumber' => $vehicle['serialNumber'] ?? null,
                'vin' => $vehicle['vin'] ?? null,
                'deviceType' => $vehicle['deviceType'] ?? null,
                'comment' => $vehicle['comment'] ?? null,
                'truckType' => $vehicle['truckType'] ?? null,
                'vehicleType' => $vehicle['vehicleType'] ?? $vehicle['truckType'] ?? null,
                'makeModel' => $vehicle['makeModel'] ?? null,
                'cargoCapacityKg' => $vehicle['cargoCapacityKg'] ?? null,
                'registrationExpiryDate' => $vehicle['registrationExpiryDate'] ?? null,
                'insuranceExpiryDate' => $vehicle['insuranceExpiryDate'] ?? null,
                'registrationDaysRemaining' => $vehicle['registrationDaysRemaining'] ?? null,
                'insuranceDaysRemaining' => $vehicle['insuranceDaysRemaining'] ?? null,
                'year' => $vehicle['year'] ?? null,
                'driver' => $vehicle['driver'] ?? 'Unassigned',
                'status' => $vehicle['status'] ?? 'available',
                'isDriving' => ($vehicle['isDriving'] ?? false) === true,
                'ignitionOn' => ($vehicle['isDriving'] ?? false) === true,
                'isCommunicating' => ($vehicle['isCommunicating'] ?? false) === true,
                'speed' => (int) ($vehicle['speed'] ?? 0),
                'bearing' => (float) ($vehicle['bearing'] ?? 0),
                'latitude' => (float) ($vehicle['latitude'] ?? 0),
                'longitude' => (float) ($vehicle['longitude'] ?? 0),
                'lastGeotabAt' => $vehicle['lastGeotabAt'] ?? $vehicle['lastUpdated'] ?? null,
                'lastUpdated' => $vehicle['lastUpdated'] ?? null,
                'currentZone' => $vehicle['currentZone'] ?? null,
                'destinationZone' => $vehicle['destinationZone'] ?? null,
                'arrivalState' => $vehicle['arrivalState'] ?? 'idle',
                'currentLocationLabel' => $vehicle['currentLocationLabel'] ?? null,
                'routeName' => $vehicle['assignedRoute'] ?? $vehicle['routeName'] ?? null,
                'routeStops' => $vehicle['routeStops'] ?? [],
                'healthStatus' => $vehicle['healthStatus'] ?? 'healthy',
                'healthScore' => $vehicle['healthScore'] ?? null,
                'healthAlerts' => $vehicle['healthAlerts'] ?? [],
                'recentFaults' => $vehicle['recentFaults'] ?? [],
                'recentExceptions' => $vehicle['recentExceptions'] ?? [],
                'fuelCapacity' => $vehicle['fuelCapacity'] ?? null,
                'fuelLevelRatio' => $vehicle['fuelLevelRatio'] ?? null,
                'fuelLevelSupported' => ($vehicle['fuelLevelSupported'] ?? false) === true,
                'odometerKm' => $vehicle['odometerKm'] ?? null,
                'mileage' => $vehicle['mileage'] ?? null,
                'engineHours' => $vehicle['engineHours'] ?? null,
                'fuelEconomyKmPerLiter' => $vehicle['fuelEconomyKmPerLiter'] ?? null,
                'diagnostics' => $vehicle['diagnostics'] ?? null,
                'syncState' => 'live',
            ];
        }

        if ($vehicles !== []) {
            return $vehicles;
        }

        foreach ($this->safeGet(fn () => $this->geotab->getDevices()) as $device) {
            $deviceId = $this->idFromValue($device);
            if ($deviceId === '') {
                continue;
            }

            $vehicles[$deviceId] = [
                'geotabId' => $deviceId,
                'plate' => $this->plateForDevice($device),
                'driver' => 'Unassigned',
                'status' => 'available',
                'isDriving' => false,
                'ignitionOn' => false,
                'isCommunicating' => false,
                'speed' => 0,
                'bearing' => 0.0,
                'latitude' => 0.0,
                'longitude' => 0.0,
                'lastGeotabAt' => null,
                'lastUpdated' => null,
                'currentZone' => null,
                'destinationZone' => null,
                'arrivalState' => 'idle',
                'currentLocationLabel' => null,
                'routeName' => null,
                'routeStops' => [],
                'healthStatus' => 'healthy',
                'syncState' => 'live',
            ];
        }

        return $vehicles;
    }

    private function syncLiveFeedState(
        array $vehicleState,
        array $summary,
        array $definitions,
        array $resolvedDiagnostics,
        array $diagnosticIdToAlias,
    ): array {
        if (! $this->liveStateHasCoordinates($vehicleState)) {
            $bootstrapStatusRows = $this->safeGet(
                fn () => $this->geotab->getDeviceStatusInfo(array_values($resolvedDiagnostics)),
            );

            foreach ($bootstrapStatusRows as $row) {
                if (! is_array($row)) {
                    continue;
                }

                $this->applyDeviceStatusFeedRow($vehicleState, $row, $definitions, $diagnosticIdToAlias);
            }
        }

        $statusDataRows = $this->consumeGeotabFeed(
            'StatusData',
            fn (?string $cursor, ?Carbon $fromDate): array => $this->geotab->getStatusDataFeed($cursor, [], 1000, $fromDate),
            1000,
            ['diagnosticAliases' => $diagnosticIdToAlias],
        );

        foreach ($statusDataRows as $row) {
            if (! is_array($row)) {
                continue;
            }

            $this->applyStatusDataFeedRow($vehicleState, $row, $definitions, $diagnosticIdToAlias);
        }

        $logRows = $this->consumeGeotabFeed(
            'LogRecord',
            fn (?string $cursor, ?Carbon $fromDate): array => $this->geotab->getLogRecordFeed($cursor, 1000, $fromDate),
            1000,
        );

        foreach ($logRows as $row) {
            if (! is_array($row)) {
                continue;
            }

            $this->applyLogRecordFeedRow($vehicleState, $row);
        }

        $tripRows = $this->consumeGeotabFeed(
            'Trip',
            fn (?string $cursor, ?Carbon $fromDate): array => $this->geotab->getTripFeed($cursor, [], 200, $fromDate),
            200,
        );

        foreach ($tripRows as $row) {
            if (! is_array($row)) {
                continue;
            }

            $this->applyTripFeedRow($vehicleState, $row, $summary);
        }

        return $vehicleState;
    }

    private function liveStateHasCoordinates(array $vehicleState): bool
    {
        foreach ($vehicleState as $vehicle) {
            if (! is_array($vehicle)) {
                continue;
            }

            $latitude = (float) ($vehicle['latitude'] ?? 0);
            $longitude = (float) ($vehicle['longitude'] ?? 0);
            if ($latitude !== 0.0 || $longitude !== 0.0) {
                return true;
            }
        }

        return false;
    }

    private function consumeGeotabFeed(string $typeName, callable $resolver, int $resultsLimit, array $options = []): array
    {
        if (! (bool) config('geotab.http_feed_sync', false)) {
            return [];
        }

        $result = $this->feedHarvester->sync($typeName, $resultsLimit, $resolver, [
            ...$options,
            'source' => 'live-endpoint',
            'seedFrom' => now()->subDay(),
        ]);

        return is_array($result['rows'] ?? null) ? $result['rows'] : [];
    }

    private function applyDeviceStatusFeedRow(
        array &$vehicleState,
        array $row,
        array $definitions,
        array $diagnosticIdToAlias,
    ): void {
        $deviceId = $this->idFromValue(data_get($row, 'device'));
        if ($deviceId === '') {
            return;
        }

        $vehicle = $vehicleState[$deviceId] ?? $this->seedLiveVehicles(['vehicles' => []])[$deviceId] ?? [
            'geotabId' => $deviceId,
            'routeStops' => [],
            'status' => 'available',
            'healthStatus' => 'healthy',
        ];

        $driverName = $this->userDisplayName(data_get($row, 'driver'));
        $speed = (float) data_get($row, 'speed', $vehicle['speed'] ?? 0);
        $isDriving = data_get($row, 'isDriving') === true || $speed > 1.0;
        $telemetry = $this->buildTelemetryEntry($row, $definitions, $diagnosticIdToAlias);

        $vehicleState[$deviceId] = [
            ...$vehicle,
            'geotabId' => $deviceId,
            'driver' => $driverName !== '' ? $driverName : ($vehicle['driver'] ?? 'Unassigned'),
            'status' => $isDriving ? 'on trip' : ($vehicle['status'] ?? 'available'),
            'isDriving' => $isDriving,
            'ignitionOn' => $this->diagnosticBoolean($telemetry['ignitionOn'] ?? null, $speed > 0 || $isDriving || (($vehicle['ignitionOn'] ?? false) === true)),
            'isCommunicating' => data_get($row, 'isCommunicating', $vehicle['isCommunicating'] ?? false) === true,
            'speed' => $speed,
            'bearing' => (float) data_get($row, 'bearing', $vehicle['bearing'] ?? 0),
            'latitude' => (float) data_get($row, 'latitude', $vehicle['latitude'] ?? 0),
            'longitude' => (float) data_get($row, 'longitude', $vehicle['longitude'] ?? 0),
            'lastGeotabAt' => $this->parseDate(data_get($row, 'dateTime'))?->toIso8601String()
                ?? ($vehicle['lastGeotabAt'] ?? null),
            'lastUpdated' => $this->parseDate(data_get($row, 'dateTime'))?->toIso8601String()
                ?? ($vehicle['lastUpdated'] ?? null),
            'syncState' => 'live',
        ];
    }

    private function applyStatusDataFeedRow(
        array &$vehicleState,
        array $row,
        array $definitions,
        array $diagnosticIdToAlias,
    ): void {
        $deviceId = $this->idFromValue(data_get($row, 'device'));
        $diagnosticId = $this->idFromValue(data_get($row, 'diagnostic'));
        $alias = $diagnosticIdToAlias[$diagnosticId] ?? null;

        if ($deviceId === '' || $alias === null || ! isset($vehicleState[$deviceId])) {
            return;
        }

        $vehicle = $vehicleState[$deviceId];
        $updatedAt = $this->parseDate(data_get($row, 'dateTime'))?->toIso8601String()
            ?? ($vehicle['lastGeotabAt'] ?? null);

        if ($alias === 'ignitionOn') {
            $vehicle['ignitionOn'] = $this->normalizeBooleanDiagnostic(data_get($row, 'data')) ?? ($vehicle['ignitionOn'] ?? false);
        }

        $entry = isset($definitions[$alias])
            ? $this->statusDataTelemetryEntry($row, $definitions[$alias])
            : null;
        if ($entry !== null) {
            $telemetry = is_array($vehicle['telemetry'] ?? null)
                ? $vehicle['telemetry']
                : $this->emptyTelemetryEntry($definitions);
            $vehicle['telemetry'] = $this->mergeTelemetryStatusDataEntry($telemetry, $alias, $entry);
            $vehicle['diagnostics'] = $vehicle['telemetry'];

            if ($alias === 'rawOdometer') {
                $vehicle['odometerKm'] = $entry['value'];
                $vehicle['mileage'] = number_format((float) $entry['value'], 0);
            } elseif (in_array($alias, ['engineHours', 'rawEngineHours'], true)) {
                $vehicle['engineHours'] = $entry['value'];
            } elseif ($alias === 'fuelLevel') {
                $ratio = $this->fuelLevelRatioFromTelemetry(
                    is_numeric($entry['value'] ?? null) ? (float) $entry['value'] : null,
                    $vehicle['fuelCapacity'] ?? null,
                );
                if ($ratio !== null) {
                    $vehicle['fuelLevelRatio'] = $ratio;
                    $vehicle['fuelLevelSupported'] = true;
                }
            }
        }

        $vehicle['lastGeotabAt'] = $updatedAt;
        $vehicle['lastUpdated'] = $updatedAt;
        $vehicle['syncState'] = 'live';
        $vehicleState[$deviceId] = $vehicle;
    }

    private function applyLogRecordFeedRow(array &$vehicleState, array $row): void
    {
        $deviceId = $this->idFromValue(data_get($row, 'device'));
        if ($deviceId === '' || ! isset($vehicleState[$deviceId])) {
            return;
        }

        $vehicle = $vehicleState[$deviceId];
        $nextLatitude = (float) data_get($row, 'latitude', $vehicle['latitude'] ?? 0);
        $nextLongitude = (float) data_get($row, 'longitude', $vehicle['longitude'] ?? 0);
        $previousLatitude = (float) ($vehicle['latitude'] ?? 0);
        $previousLongitude = (float) ($vehicle['longitude'] ?? 0);
        $speed = (float) data_get($row, 'speed', $vehicle['speed'] ?? 0);
        $bearing = (float) ($vehicle['bearing'] ?? 0);

        if (($previousLatitude !== 0.0 || $previousLongitude !== 0.0)
            && ($nextLatitude !== $previousLatitude || $nextLongitude !== $previousLongitude)) {
            $bearing = $this->bearingBetweenCoordinates($previousLatitude, $previousLongitude, $nextLatitude, $nextLongitude);
        }

        $updatedAt = $this->parseDate(data_get($row, 'dateTime'))?->toIso8601String()
            ?? ($vehicle['lastGeotabAt'] ?? null);

        $vehicleState[$deviceId] = [
            ...$vehicle,
            'latitude' => $nextLatitude,
            'longitude' => $nextLongitude,
            'speed' => $speed,
            'bearing' => $bearing,
            'isDriving' => $speed > 1.0,
            'ignitionOn' => $speed > 0 || (($vehicle['ignitionOn'] ?? false) === true),
            'lastGeotabAt' => $updatedAt,
            'lastUpdated' => $updatedAt,
            'syncState' => 'live',
        ];

        $this->persistGpsLogRow(
            $row,
            trim((string) ($vehicle['activeTripId'] ?? '')) ?: null,
            $deviceId,
            $bearing,
        );
    }

    private function applyTripFeedRow(array &$vehicleState, array $row, array $summary): void
    {
        $deviceId = $this->idFromValue(data_get($row, 'device'));
        if ($deviceId === '' || ! isset($vehicleState[$deviceId])) {
            return;
        }

        $vehicle = $vehicleState[$deviceId];
        $start = $this->parseDate(data_get($row, 'start'));
        $stop = $this->parseDate(data_get($row, 'stop'));
        $stopDuration = (int) data_get($row, 'stopDuration', 0);
        $isActiveTrip = $start !== null && ($stop === null || $stopDuration === 0);

        if ($isActiveTrip) {
            $vehicle['status'] = 'on trip';
            $vehicle['isDriving'] = ((float) ($vehicle['speed'] ?? 0)) > 1.0;
            $vehicle['ignitionOn'] = true;
            $vehicle['activeTripId'] = 'LIVE-'.strtoupper(substr($deviceId, -6));
        }

        foreach (is_array($summary['trips'] ?? null) ? $summary['trips'] : [] as $trip) {
            if (($trip['deviceGeotabId'] ?? null) !== $deviceId) {
                continue;
            }

            $vehicle['activeTripId'] = $trip['tripId'] ?? $vehicle['activeTripId'] ?? null;
            $vehicle['destinationZone'] = $trip['destinationZone'] ?? $vehicle['destinationZone'] ?? null;
            $vehicle['routeName'] = $trip['routeName'] ?? $vehicle['routeName'] ?? null;
            $vehicle['routeStops'] = $trip['routedPlaces'] ?? $vehicle['routeStops'] ?? [];
            break;
        }

        $vehicleState[$deviceId] = $vehicle;
    }

    private function feedCheckpoint(string $typeName): ?string
    {
        if ($this->feedCheckpointTableAvailable()) {
            $checkpoint = GeotabFeedCheckpoint::query()->where('type_name', $typeName)->first();
            if ($checkpoint !== null) {
                $cursor = trim((string) ($checkpoint->cursor ?? ''));

                return $cursor !== '' ? $cursor : null;
            }
        }

        $cached = trim((string) Cache::get('geotab_feed_checkpoint_'.$typeName, ''));

        return $cached !== '' ? $cached : null;
    }

    private function storeFeedCheckpoint(string $typeName, ?string $cursor): void
    {
        $cursor = trim((string) $cursor);
        if ($cursor === '') {
            return;
        }

        Cache::put('geotab_feed_checkpoint_'.$typeName, $cursor, now()->addDays(14));

        if (! $this->feedCheckpointTableAvailable()) {
            return;
        }

        GeotabFeedCheckpoint::query()->updateOrCreate(
            ['type_name' => $typeName],
            [
                'cursor' => $cursor,
                'meta' => ['source' => 'live-feed'],
                'synced_at' => now(),
            ],
        );
    }

    private function feedCheckpointTableAvailable(): bool
    {
        try {
            return Schema::hasTable('geotab_feed_checkpoints');
        } catch (\Throwable) {
            return false;
        }
    }

    private function buildSnapshot(): array
    {
        if (! $this->geotab->isConfigured()) {
            $empty = $this->emptySnapshot();
            $empty['vehicles'] = $this->mergeManualVehicles([], [], []);

            return $empty;
        }

        $definitions = $this->diagnosticDefinitions();
        $resolvedDiagnostics = $this->resolvedDiagnostics();

        $devices = $this->safeGet(fn () => $this->geotab->getDevices());
        $statusList = $this->safeGet(fn () => $this->geotab->getDeviceStatusInfo(array_values($resolvedDiagnostics)));
        $drivers = $this->safeGet(
            fn () => $this->geotab->getDrivers(),
            ['stage' => 'snapshot_drivers'],
            true,
        );
        $zones = $this->safeGet(fn () => $this->geotab->getZones(now(), 500));
        $routes = $this->safeGet(fn () => $this->geotab->getRoutes(null, null, 500));
        $routePlanItems = $this->safeGet(fn () => $this->geotab->getRoutePlanItems(null, null, 1000));
        $trips = $this->safeGet(fn () => $this->geotab->getTrips(now()->subDays(14), now(), 250));
        $dutyLogs = $this->safeGet(fn () => $this->geotab->getDutyStatusLogs(now()->subDays(7), now(), 250));
        $fillUps = $this->safeGet(fn () => $this->geotab->getFillUps(now()->subDays(30), now(), 200));
        $fuelAndEnergy = $this->safeGet(fn () => $this->geotab->getFuelAndEnergyUsed(now()->subDays(7), now(), 250));
        $fuelTransactions = $this->safeGet(fn () => $this->geotab->getFuelTransactions(now()->subDays(30), now(), 500));
        $chargeEvents = $this->safeGet(fn () => $this->geotab->getChargeEvents(now()->subDays(30), now(), 250));
        $exceptionEvents = $this->safeGet(fn () => $this->geotab->getExceptionEvents(now()->subDays(7), now(), 250));
        $faultData = $this->safeGet(fn () => $this->geotab->getFaultData(now()->subDays(7), now(), 250));
        $dvirLogs = $this->safeGet(fn () => $this->geotab->getDvirLogs(now()->subDays(30), now(), 250));
        $driverChanges = $this->safeGet(fn () => $this->geotab->getDriverChanges(now()->subDays(30), now(), 500));
        $shipmentLogs = $this->safeGet(fn () => $this->geotab->getShipmentLogs(now()->subDays(30), now(), 250));
        $ioxAddOns = $this->safeGet(fn () => $this->geotab->getIoxAddOns(null, null, 250));

        $deviceIndex = [];
        foreach ($devices as $device) {
            $deviceId = $this->idFromValue($device);
            if ($deviceId !== '') {
                $deviceIndex[$deviceId] = $device;
            }
        }

        $zoneIndex = [];
        $zonesView = [];
        foreach ($zones as $zone) {
            $zoneId = $this->idFromValue($zone);
            if ($zoneId === '') {
                continue;
            }

            $zoneIndex[$zoneId] = $zone;
            $zonesView[] = $this->formatZone($zone);
        }
        $zonesView = $this->mergeFleetZones($this->localFleetZones(), $zonesView);

        $routePlanItemsByRoute = $this->routePlanItemsByRoute($routePlanItems);
        $routesByDevice = [];
        $routesView = [];
        foreach ($routes as $route) {
            $routeId = $this->idFromValue($route);
            $routeView = $this->formatRoute($route, $zoneIndex, $routePlanItemsByRoute[$routeId] ?? []);
            if ($routeView === null) {
                continue;
            }

            $routesView[] = $routeView;
            $deviceId = (string) ($routeView['deviceId'] ?? '');
            if ($deviceId !== '') {
                $routesByDevice[$deviceId][] = $routeView;
            }
        }
        $this->feedHarvester->persistRouteStops($routesView);

        $exceptionsByDevice = [];
        foreach ($exceptionEvents as $event) {
            $deviceId = $this->idFromValue(data_get($event, 'device'));
            if ($deviceId === '') {
                continue;
            }

            $exceptionsByDevice[$deviceId][] = $this->formatExceptionEvent($event);
        }

        $faultsByDevice = [];
        foreach ($faultData as $fault) {
            $deviceId = $this->idFromValue(data_get($fault, 'device'));
            if ($deviceId === '') {
                continue;
            }

            $faultsByDevice[$deviceId][] = $this->formatFaultData($fault);
        }

        $driverChangesByDevice = [];
        foreach ($driverChanges as $change) {
            $deviceId = $this->idFromValue(data_get($change, 'device'));
            if ($deviceId === '') {
                continue;
            }

            $driverChangesByDevice[$deviceId][] = $this->formatDriverChange($change);
        }

        $shipmentsByDevice = [];
        foreach ($shipmentLogs as $shipment) {
            $deviceId = $this->idFromValue(data_get($shipment, 'device'));
            if ($deviceId === '') {
                continue;
            }

            $shipmentsByDevice[$deviceId][] = $this->formatShipmentLog($shipment);
        }

        $ioxByDevice = [];
        foreach ($ioxAddOns as $addOn) {
            $deviceId = $this->idFromValue(data_get($addOn, 'device'));
            if ($deviceId === '') {
                continue;
            }

            $ioxByDevice[$deviceId][] = $this->formatIoxAddOn($addOn);
        }

        $statusByDevice = [];
        $telemetryByDevice = [];
        $diagnosticIdToAlias = [];
        foreach ($resolvedDiagnostics as $alias => $diagnostic) {
            $diagnosticId = (string) ($diagnostic['id'] ?? '');
            if ($diagnosticId !== '') {
                $diagnosticIdToAlias[$diagnosticId] = $alias;
            }
        }

        foreach ($statusList as $status) {
            $deviceId = $this->idFromValue(data_get($status, 'device'));
            if ($deviceId === '') {
                continue;
            }

            $statusByDevice[$deviceId] = $status;
            $telemetryByDevice[$deviceId] = $this->buildTelemetryEntry(
                $status,
                $definitions,
                $diagnosticIdToAlias,
            );
        }

        $telemetryByDevice = $this->hydrateLatestTelemetryFromStatusData(
            $telemetryByDevice,
            $resolvedDiagnostics,
            $definitions,
            [
                'fuelLevel',
                'totalFuelUsed',
                'totalIdleFuelUsed',
                'engineHours',
                'rawEngineHours',
                'rawOdometer',
            ],
        );

        $telemetryByDevice = $this->hydrateTemperatureTelemetryFromStatusData(
            $telemetryByDevice,
            $resolvedDiagnostics,
            $definitions,
        );

        $addressLookup = $this->buildAddressLookup($trips, $statusList);

        $historicalTrips = [];
        $liveTrips = [];
        $tripStatsByDevice = [];
        $tripStatsByDriver = [];

        foreach ($trips as $trip) {
            $deviceId = $this->idFromValue(data_get($trip, 'device'));
            $device = $deviceIndex[$deviceId] ?? [];
            $driver = data_get($trip, 'driver');
            $driverId = $this->idFromValue($driver);
            $driverName = $this->userDisplayName($driver);
            $plate = $this->plateForDevice($device);
            $distanceKm = round((float) data_get($trip, 'distance', 0), 2);
            $amount = $this->estimateTripAmount($distanceKm);
            $start = $this->parseDate(data_get($trip, 'start'));
            $stop = $this->parseDate(data_get($trip, 'stop') ?: data_get($trip, 'nextTripStart') ?: data_get($trip, 'start'));
            $tripId = $this->displayTripId($this->idFromValue($trip), 'TRP');
            $sortAt = ($stop ?? $start ?? now())->toIso8601String();
            $routeContext = $this->routeContextForDevice($deviceId, $routesByDevice, $zoneIndex);
            $originAddress = $this->addressLabelForLookup(
                data_get($trip, 'startPoint'),
                $addressLookup,
                (string) ($routeContext['originZone'] ?? 'Trip start'),
            );
            $destinationAddress = $this->addressLabelForLookup(
                data_get($trip, 'stopPoint'),
                $addressLookup,
                (string) ($routeContext['destinationZone'] ?? 'Trip stop'),
            );
            $stopPoint = $this->coordinateParts((array) data_get($trip, 'stopPoint', []));
            $tripCurrentZone = $stopPoint !== null
                ? $this->zoneNameForCoordinate($stopPoint['latitude'], $stopPoint['longitude'], $zones)
                : null;

            $historicalTrips[] = [
                'tripId' => $tripId,
                'geotabId' => $this->idFromValue($trip),
                'deviceGeotabId' => $deviceId,
                'date' => $this->displayDate($stop ?? $start),
                'customer' => $this->tripCustomerLabel(
                    $trip,
                    $destinationAddress,
                    (string) ($routeContext['destinationZone'] ?? ''),
                ),
                'phone' => 'N/A',
                'origin' => $originAddress,
                'destination' => $destinationAddress,
                'vehicle' => $plate,
                'driver' => $driverName,
                'status' => 'completed',
                'amount' => $this->money($amount),
                'delay' => '',
                'hasDelay' => false,
                'distanceKm' => $distanceKm,
                'averageSpeed' => round((float) data_get($trip, 'averageSpeed', 0), 1),
                'maximumSpeed' => round((float) data_get($trip, 'maximumSpeed', 0), 1),
                'drivingMinutes' => $this->secondsToMinutes(data_get($trip, 'drivingDuration', 0)),
                'idlingMinutes' => $this->secondsToMinutes(data_get($trip, 'idlingDuration', 0)),
                'notes' => 'Synced from MyGeotab trip history',
                'startedAt' => $start?->toIso8601String(),
                'endedAt' => $stop?->toIso8601String(),
                'startPoint' => $this->coordinateParts(data_get($trip, 'startPoint')),
                'stopPoint' => $stopPoint,
                'routeName' => $routeContext['routeName'],
                'routedPlaces' => $routeContext['routeStops'],
                'currentZone' => $tripCurrentZone,
                'originZone' => $routeContext['originZone'],
                'destinationZone' => $routeContext['destinationZone'],
                'arrivalState' => $routeContext['destinationZone'] !== null && $tripCurrentZone === $routeContext['destinationZone']
                    ? 'arrived'
                    : 'completed',
                'arrivedAtDestination' => $routeContext['destinationZone'] !== null
                    && $tripCurrentZone === $routeContext['destinationZone'],
                'sortAt' => $sortAt,
            ];

            if ($deviceId !== '') {
                $tripStatsByDevice[$deviceId]['count'] = ($tripStatsByDevice[$deviceId]['count'] ?? 0) + 1;
                $tripStatsByDevice[$deviceId]['revenue'] = ($tripStatsByDevice[$deviceId]['revenue'] ?? 0) + $amount;
                $tripStatsByDevice[$deviceId]['distanceKm'] = ($tripStatsByDevice[$deviceId]['distanceKm'] ?? 0) + $distanceKm;
                $tripStatsByDevice[$deviceId]['latestTripDate'] = $sortAt;
            }

            $driverKey = $driverId !== '' ? $driverId : $driverName;
            if ($driverKey !== '') {
                $tripStatsByDriver[$driverKey]['count'] = ($tripStatsByDriver[$driverKey]['count'] ?? 0) + 1;
                $tripStatsByDriver[$driverKey]['revenue'] = ($tripStatsByDriver[$driverKey]['revenue'] ?? 0) + $amount;
                $tripStatsByDriver[$driverKey]['speedEvents'] = ($tripStatsByDriver[$driverKey]['speedEvents'] ?? 0)
                    + (int) data_get($trip, 'speedRange1', 0)
                    + ((int) data_get($trip, 'speedRange2', 0) * 2)
                    + ((int) data_get($trip, 'speedRange3', 0) * 3);
            }
        }

        foreach ($statusByDevice as $deviceId => $status) {
            if (data_get($status, 'isDriving') !== true) {
                continue;
            }

            $device = $deviceIndex[$deviceId] ?? [];
            $driver = data_get($status, 'driver');
            $driverName = $this->userDisplayName($driver);
            $plate = $this->plateForDevice($device);
            $updatedAt = $this->parseDate(data_get($status, 'dateTime'));
            $routeContext = $this->routeContextForDevice($deviceId, $routesByDevice, $zoneIndex);
            $liveAddress = $this->addressLabelForLookup(
                $status,
                $addressLookup,
                'Live location',
            );
            $currentZone = $this->zoneNameForCoordinate(
                (float) data_get($status, 'latitude', 0),
                (float) data_get($status, 'longitude', 0),
                $zones,
            );
            $arrivalState = $this->arrivalState(
                data_get($status, 'isDriving') === true,
                $currentZone,
                $routeContext['destinationZone'],
            );

            $liveTrips[] = [
                'tripId' => 'LIVE-'.strtoupper(substr($deviceId, -6)),
                'geotabId' => $deviceId,
                'deviceGeotabId' => $deviceId,
                'date' => $this->displayDate($updatedAt),
                'customer' => trim((string) ($routeContext['destinationZone'] ?? '')) !== ''
                    ? trim((string) $routeContext['destinationZone'])
                    : ($liveAddress !== 'Live location' ? $liveAddress : 'Live Geotab Trip'),
                'phone' => 'N/A',
                'origin' => $liveAddress,
                'destination' => $this->sanitizeText(data_get($device, 'comment', ''), '') !== ''
                    ? $this->sanitizeText(data_get($device, 'comment', ''), '')
                    : ((string) ($routeContext['destinationZone'] ?? 'In transit')),
                'vehicle' => $plate,
                'driver' => $driverName,
                'status' => 'dispatched',
                'amount' => $this->money(0),
                'delay' => '',
                'hasDelay' => false,
                'distanceKm' => 0,
                'averageSpeed' => round((float) data_get($status, 'speed', 0), 1),
                'maximumSpeed' => round((float) data_get($status, 'speed', 0), 1),
                'drivingMinutes' => $this->secondsToMinutes(data_get($status, 'currentStateDuration', 0)),
                'idlingMinutes' => 0,
                'notes' => 'Live trip inferred from current DeviceStatusInfo',
                'startedAt' => $updatedAt?->toIso8601String(),
                'endedAt' => null,
                'startPoint' => $this->coordinateParts($status),
                'stopPoint' => null,
                'routeName' => $routeContext['routeName'],
                'routedPlaces' => $routeContext['routeStops'],
                'currentZone' => $currentZone,
                'originZone' => $routeContext['originZone'],
                'destinationZone' => $routeContext['destinationZone'],
                'arrivalState' => $arrivalState,
                'arrivedAtDestination' => $arrivalState === 'arrived',
                'sortAt' => ($updatedAt ?? now())->toIso8601String(),
            ];
        }

        usort($historicalTrips, fn (array $a, array $b) => strcmp($b['sortAt'], $a['sortAt']));
        usort($liveTrips, fn (array $a, array $b) => strcmp($b['sortAt'], $a['sortAt']));

        $fuelPriceSettings = $this->fuelPriceSettingsPayload();
        $fillUpEvents = [];
        $fillUpStatsByDevice = [];
        foreach ($fillUps as $fillUp) {
            $deviceId = $this->idFromValue(data_get($fillUp, 'device'));
            $device = $deviceIndex[$deviceId] ?? [];
            $date = $this->parseDate(data_get($fillUp, 'dateTime'));
            $volume = (float) data_get($fillUp, 'volume', data_get($fillUp, 'derivedVolume', 0));
            $cost = (float) data_get($fillUp, 'cost', 0);
            $pricePerLiter = $volume > 0 ? round($cost / $volume, 2) : 0.0;
            $coordinate = $this->coordinateParts(data_get($fillUp, 'location'));

            $fillUpEvents[] = $this->withFuelEstimate([
                'id' => $this->idFromValue($fillUp) ?: 'fillup-'.substr(md5(json_encode($fillUp)), 0, 12),
                'sourceRecordId' => $this->idFromValue($fillUp) ?: substr(md5(json_encode($fillUp)), 0, 12),
                'vehicle' => $this->plateForDevice($device),
                'vehicleGeotabId' => $deviceId ?: null,
                'driver' => $this->userDisplayName(data_get($fillUp, 'driver')),
                'station' => $this->sanitizeText(data_get($fillUp, 'vendorName', ''), '') !== ''
                    ? $this->sanitizeText(data_get($fillUp, 'vendorName', ''), '')
                    : 'Geotab fuel event',
                'stationName' => $this->sanitizeText(data_get($fillUp, 'vendorName', ''), '') ?: null,
                'date' => $this->displayDate($date),
                'dateTime' => $date?->toIso8601String(),
                'latitude' => $coordinate['latitude'] ?? null,
                'longitude' => $coordinate['longitude'] ?? null,
                'volumeLiters' => round($volume, 2),
                'liters' => round($volume, 2),
                'pricePerLiter' => $pricePerLiter,
                'cost' => $cost,
                'totalCost' => round($cost, 2),
                'costLabel' => $this->money($cost),
                'currencyCode' => (string) data_get($fillUp, 'currencyCode', 'PHP'),
                'distanceKm' => round(((float) data_get($fillUp, 'distance', 0)) / 1000, 2),
                'odometerKm' => round(((float) data_get($fillUp, 'odometer', 0)) / 1000, 2),
                'totalFuelUsedLiters' => round((float) data_get($fillUp, 'totalFuelUsed', 0), 2),
                'tankCapacityLiters' => $this->fuelCapacityForFillUp($fillUp),
            ], $fuelPriceSettings);

            if ($deviceId !== '') {
                $fillUpStatsByDevice[$deviceId]['volume'] = ($fillUpStatsByDevice[$deviceId]['volume'] ?? 0) + $volume;
                $fillUpStatsByDevice[$deviceId]['cost'] = ($fillUpStatsByDevice[$deviceId]['cost'] ?? 0) + $cost;
                $fillUpStatsByDevice[$deviceId]['events'] = ($fillUpStatsByDevice[$deviceId]['events'] ?? 0) + 1;
                $fillUpStatsByDevice[$deviceId]['tankCapacity'] = $this->fuelCapacityForFillUp($fillUp)
                    ?: ($fillUpStatsByDevice[$deviceId]['tankCapacity'] ?? null);
                $fillUpStatsByDevice[$deviceId]['latestOdometerKm'] = max(
                    (float) ($fillUpStatsByDevice[$deviceId]['latestOdometerKm'] ?? 0),
                    round(((float) data_get($fillUp, 'odometer', 0)) / 1000, 2),
                );
                $fillUpStatsByDevice[$deviceId]['lastEventAt'] = max(
                    (string) ($fillUpStatsByDevice[$deviceId]['lastEventAt'] ?? ''),
                    (string) ($date?->toIso8601String() ?? ''),
                );
            }
        }

        usort($fillUpEvents, fn (array $a, array $b) => strcmp((string) ($b['dateTime'] ?? ''), (string) ($a['dateTime'] ?? '')));

        $fuelTransactionEvents = [];
        foreach ($fuelTransactions as $transaction) {
            $deviceId = $this->idFromValue(data_get($transaction, 'device'));
            $device = $deviceIndex[$deviceId] ?? [];
            $fuelTransactionEvents[] = $this->withFuelEstimate(
                $this->formatFuelTransaction($transaction, $device),
                $fuelPriceSettings,
            );
        }
        usort($fuelTransactionEvents, fn (array $a, array $b) => strcmp((string) ($b['dateTime'] ?? ''), (string) ($a['dateTime'] ?? '')));

        $chargeEventRows = [];
        foreach ($chargeEvents as $event) {
            $deviceId = $this->idFromValue(data_get($event, 'device'));
            $device = $deviceIndex[$deviceId] ?? [];
            $chargeEventRows[] = $this->formatChargeEvent($event, $device);
        }
        usort($chargeEventRows, fn (array $a, array $b) => strcmp((string) ($b['startTime'] ?? ''), (string) ($a['startTime'] ?? '')));

        $fuelUsageByDevice = [];
        foreach ($fuelAndEnergy as $entry) {
            $deviceId = $this->idFromValue(data_get($entry, 'device'));
            if ($deviceId === '') {
                continue;
            }

            $fuelUsageByDevice[$deviceId]['fuelUsedLiters'] = ($fuelUsageByDevice[$deviceId]['fuelUsedLiters'] ?? 0)
                + (float) data_get($entry, 'totalFuelUsed', 0);
            $fuelUsageByDevice[$deviceId]['idlingFuelUsedLiters'] = ($fuelUsageByDevice[$deviceId]['idlingFuelUsedLiters'] ?? 0)
                + (float) data_get($entry, 'totalIdlingFuelUsedL', 0);
            $fuelUsageByDevice[$deviceId]['energyUsedKwh'] = ($fuelUsageByDevice[$deviceId]['energyUsedKwh'] ?? 0)
                + (float) data_get($entry, 'totalEnergyUsedKwh', 0);
            $fuelUsageByDevice[$deviceId]['idlingEnergyUsedKwh'] = ($fuelUsageByDevice[$deviceId]['idlingEnergyUsedKwh'] ?? 0)
                + (float) data_get($entry, 'totalIdlingEnergyUsedKwh', 0);
        }

        $latestDutyByDriver = [];
        foreach ($dutyLogs as $log) {
            $driver = data_get($log, 'driver');
            $driverId = $this->idFromValue($driver);
            $driverName = $this->userDisplayName($driver);
            $driverKey = $driverId !== '' ? $driverId : $driverName;
            if ($driverKey === '') {
                continue;
            }

            $date = $this->parseDate(data_get($log, 'dateTime'));
            $current = $latestDutyByDriver[$driverKey]['dateTime'] ?? null;
            if ($current === null || (($date?->toIso8601String() ?? '') > $current)) {
                $latestDutyByDriver[$driverKey] = [
                    'log' => $log,
                    'dateTime' => $date?->toIso8601String(),
                ];
            }
        }

        $compliance = [];
        foreach ($latestDutyByDriver as $entry) {
            $log = $entry['log'];
            $deviceId = $this->idFromValue(data_get($log, 'device'));
            $device = $deviceIndex[$deviceId] ?? [];
            $driver = data_get($log, 'driver');
            $status = (string) data_get($log, 'status', 'Unknown');
            $compliance[] = [
                'driver' => $this->userDisplayName($driver),
                'driverId' => $this->idFromValue($driver),
                'vehicle' => $this->plateForDevice($device),
                'status' => $status,
                'dateTime' => data_get($log, 'dateTime'),
                'displayDate' => $this->displayDate($this->parseDate(data_get($log, 'dateTime'))),
                'engineHours' => round(((float) data_get($log, 'engineHours', 0)) / 3600, 1),
                'odometerKm' => round(((float) data_get($log, 'odometer', 0)) / 1000, 1),
                'location' => $this->coordinateLabel(data_get($log, 'location'), 'No location'),
                'hasMalfunction' => ! empty(data_get($log, 'malfunction')),
                'isIgnored' => data_get($log, 'isIgnored') === true,
            ];
        }

        usort($compliance, fn (array $a, array $b) => strcmp((string) ($b['dateTime'] ?? ''), (string) ($a['dateTime'] ?? '')));

        $vehicles = [];
        foreach ($devices as $device) {
            $deviceId = $this->idFromValue($device);
            if ($deviceId === '') {
                continue;
            }

            $status = $statusByDevice[$deviceId] ?? [];
            $telemetry = $telemetryByDevice[$deviceId] ?? $this->emptyTelemetryEntry($definitions);
            $isDriving = data_get($status, 'isDriving') === true;
            $tripStats = $tripStatsByDevice[$deviceId] ?? [];
            $fillUpStats = $fillUpStatsByDevice[$deviceId] ?? [];
            $fuelUsage = $fuelUsageByDevice[$deviceId] ?? [];

            $fuelLevelValue = $this->diagnosticNumeric($telemetry, 'fuelLevel');
            $fuelCapacity = $this->deviceFuelTankCapacity($device)
                ?? $this->diagnosticNumeric($telemetry, 'fuelTankCapacity')
                ?? ($fillUpStats['tankCapacity'] ?? null);
            $fuelLevelRatio = $this->fuelLevelRatioFromTelemetry($fuelLevelValue, $fuelCapacity);
            $odometerKm = $this->diagnosticNumeric($telemetry, 'rawOdometer') ?? (float) ($fillUpStats['latestOdometerKm'] ?? 0);
            $engineHours = $this->diagnosticNumeric($telemetry, 'engineHours')
                ?? $this->diagnosticNumeric($telemetry, 'rawEngineHours');
            $lastUpdated = data_get($status, 'dateTime') ?: ($tripStats['latestTripDate'] ?? null);
            $latitude = round((float) data_get($status, 'latitude', 0), 6);
            $longitude = round((float) data_get($status, 'longitude', 0), 6);
            $assetTags = $this->assetTags($device, $telemetry);
            $deliveryFit = $this->deliveryFit($device, $telemetry);
            $routeContext = $this->routeContextForDevice($deviceId, $routesByDevice, $zoneIndex);
            $currentZone = $this->zoneNameForCoordinate(
                $latitude,
                $longitude,
                $zones,
            );
            $arrivalState = $this->arrivalState($isDriving, $currentZone, $routeContext['destinationZone']);
            $faults = array_slice($faultsByDevice[$deviceId] ?? [], 0, 8);
            $exceptions = array_slice($exceptionsByDevice[$deviceId] ?? [], 0, 8);
            $fuelUsedForEconomy = (float) ($fuelUsage['fuelUsedLiters'] ?? 0);
            $fuelEconomyKmPerLiter = $fuelUsedForEconomy > 0
                ? $this->safeDivide((float) ($tripStats['distanceKm'] ?? 0), $fuelUsedForEconomy)
                : null;
            $fuelLevelRatio ??= $this->estimatedFuelLevelRatio($device, $fuelCapacity, $fuelUsedForEconomy, (float) ($tripStats['distanceKm'] ?? 0), $odometerKm, $engineHours);
            $fuelEconomyKmPerLiter ??= $this->estimatedFuelEconomyKmPerLiter($device, $fuelUsedForEconomy, (float) ($tripStats['distanceKm'] ?? 0));
            $engineHours ??= $this->estimatedEngineHours($device, $odometerKm);
            $odometerKm = $odometerKm > 0 ? $odometerKm : $this->estimatedOdometerKm($device);
            $deviceChargeEvents = array_values(array_filter(
                $chargeEventRows,
                fn (array $row): bool => (string) ($row['geotabId'] ?? '') === $deviceId,
            ));
            $isElectric = ((float) ($fuelUsage['energyUsedKwh'] ?? 0)) > 0 || $deviceChargeEvents !== [];
            $telemetry = $this->backfillVehicleTelemetry(
                $telemetry,
                $definitions,
                $device,
                $fuelCapacity,
                $fuelLevelRatio,
                $odometerKm,
                $engineHours,
                $lastUpdated,
                $latitude,
                $longitude,
                $isElectric,
            );
            $assetProfile = $this->assetProfileForDevice($device);
            $health = $this->buildVehicleHealth(
                $telemetry,
                [
                    'isCommunicating' => data_get($status, 'isDeviceCommunicating') === true,
                ],
                $faults,
                $exceptions,
            );
            $currentLocationLabel = $this->addressLabelForLookup(
                $status,
                $addressLookup,
                'Unknown location',
            );
            $driverChangeRows = array_slice($driverChangesByDevice[$deviceId] ?? [], 0, 8);
            $shipmentRows = array_slice($shipmentsByDevice[$deviceId] ?? [], 0, 6);
            $ioxRows = $ioxByDevice[$deviceId] ?? [];
            $coldChainCapable = $ioxRows !== []
                || ($telemetry['reeferTemperatureZone1']['supported'] ?? false) === true
                || ($telemetry['cargoTemperatureZone1']['supported'] ?? false) === true
                || ($telemetry['relativeHumidity']['supported'] ?? false) === true;

            $vehicles[] = [
                'geotabId' => $deviceId,
                'name' => $this->sanitizeText(data_get($device, 'name', ''), 'Unknown'),
                'plate' => $this->plateForDevice($device),
                'serialNumber' => $this->sanitizeText(data_get($device, 'serialNumber', ''), ''),
                'vin' => $this->sanitizeText(data_get($device, 'vehicleIdentificationNumber', ''), ''),
                'deviceType' => $this->stringValue(data_get($device, 'deviceType')),
                'year' => $assetProfile['year'],
                'comment' => $this->sanitizeText(data_get($device, 'comment', ''), ''),
                'makeModel' => $assetProfile['makeModel'],
                'cargoCapacityKg' => $assetProfile['cargoCapacityKg'],
                'registrationExpiryDate' => $assetProfile['registrationExpiryDate'],
                'insuranceExpiryDate' => $assetProfile['insuranceExpiryDate'],
                'registrationDaysRemaining' => $assetProfile['registrationDaysRemaining'],
                'insuranceDaysRemaining' => $assetProfile['insuranceDaysRemaining'],
                'status' => $isDriving ? 'on trip' : 'available',
                'isDriving' => $isDriving,
                'speed' => (int) data_get($status, 'speed', 0),
                'latitude' => $latitude,
                'longitude' => $longitude,
                'bearing' => (int) data_get($status, 'bearing', 0),
                'isCommunicating' => data_get($status, 'isDeviceCommunicating') === true,
                'lastUpdated' => $lastUpdated,
                'currentLocationLabel' => $currentLocationLabel,
                'driver' => $this->userDisplayName(data_get($status, 'driver')),
                'truckType' => $assetProfile['vehicleType'],
                'vehicleType' => $assetProfile['vehicleType'],
                'assetTags' => $assetTags,
                'deliveryFit' => $deliveryFit,
                'fuelCapacity' => $fuelCapacity !== null ? number_format((float) $fuelCapacity, 0, '.', '') : 'N/A',
                'fuelLevelRatio' => $fuelLevelRatio ?? 0.0,
                'fuelLevelSupported' => (bool) data_get($telemetry, 'fuelLevel.supported', false) || $fuelLevelRatio !== null,
                'mileage' => $odometerKm > 0 ? number_format($odometerKm, 0) : '0',
                'odometerKm' => round($odometerKm, 2),
                'engineHours' => $engineHours !== null ? round($engineHours, 1) : null,
                'diagnostics' => $telemetry,
                'numTrips' => (int) ($tripStats['count'] ?? 0),
                'totalRevenue' => (int) round((float) ($tripStats['revenue'] ?? 0)),
                'distanceKm14d' => round((float) ($tripStats['distanceKm'] ?? 0), 2),
                'fuelUsedLiters7d' => round((float) ($fuelUsage['fuelUsedLiters'] ?? 0), 2),
                'idlingFuelUsedLiters7d' => round((float) ($fuelUsage['idlingFuelUsedLiters'] ?? 0), 2),
                'energyUsedKwh7d' => round((float) ($fuelUsage['energyUsedKwh'] ?? 0), 2),
                'fuelEconomyKmPerLiter' => $fuelEconomyKmPerLiter !== null ? round($fuelEconomyKmPerLiter, 2) : null,
                'assignedRoute' => $routeContext['routeName'],
                'routeStops' => $routeContext['routeStops'],
                'currentZone' => $currentZone,
                'destinationZone' => $routeContext['destinationZone'],
                'arrivalState' => $arrivalState,
                'recentDriverChanges' => $driverChangeRows,
                'shipments' => $shipmentRows,
                'ioxAddOns' => $ioxRows,
                'isElectric' => $isElectric,
                'coldChainCapable' => $coldChainCapable,
                'healthStatus' => $health['status'],
                'healthScore' => $health['score'],
                'healthAlerts' => $health['alerts'],
                'recentFaults' => $faults,
                'recentExceptions' => $exceptions,
                'lastInspection' => $this->displayShortDate($this->parseDate($lastUpdated)),
                'nextMaintenance' => $odometerKm > 0
                    ? 'At '.number_format(ceil($odometerKm / 10000) * 10000).' km'
                    : 'Monitor odometer',
                'documents' => [],
            ];
        }

        usort($vehicles, fn (array $a, array $b) => strcmp((string) ($a['plate'] ?? ''), (string) ($b['plate'] ?? '')));
        $vehicles = $this->mergeManualVehicles($vehicles, [...$historicalTrips, ...$liveTrips], [...$fillUpEvents, ...$fuelTransactionEvents]);

        $maintenance = [];
        foreach ($vehicles as $vehicle) {
            $mileageKm = (float) str_replace(',', '', (string) ($vehicle['mileage'] ?? '0'));
            $fuelAlert = (($vehicle['fuelLevelSupported'] ?? false) === true)
                && ((float) ($vehicle['fuelLevelRatio'] ?? 0) <= 0.15);
            $offline = ($vehicle['isCommunicating'] ?? false) !== true;
            $serviceDue = $mileageKm > 0 && ((int) $mileageKm % 20000) >= 18000;

            if (! $fuelAlert && ! $offline && ! $serviceDue) {
                continue;
            }

            $maintenance[] = [
                'vehicle' => $vehicle['plate'],
                'geotabId' => $vehicle['geotabId'] ?? null,
                'type' => $offline
                    ? 'Connectivity Check'
                    : ($serviceDue ? 'Preventive Maintenance' : 'Fuel Attention'),
                'description' => $offline
                    ? 'Device is not currently communicating with MyGeotab.'
                    : ($serviceDue
                        ? 'Vehicle is approaching the next preventive maintenance interval.'
                        : 'Fuel telemetry is reporting a low level threshold.'),
                'status' => $offline ? 'in progress' : 'scheduled',
                'cost' => 'N/A',
                'date' => substr((string) ($vehicle['lastUpdated'] ?? now()->toIso8601String()), 0, 10),
                'mileage' => $vehicle['mileage'],
                'priority' => $offline ? 'High' : ($serviceDue ? 'Medium' : 'Low'),
                'sourceType' => $offline ? 'geotab_status' : ($serviceDue ? 'service_threshold' : 'geotab_status'),
                'sourceRecordId' => ($vehicle['geotabId'] ?? $vehicle['plate'] ?? 'vehicle').'-'.($offline ? 'offline' : ($serviceDue ? 'service' : 'fuel')),
                'sourceSummary' => $offline ? 'DeviceStatusInfo reports the asset is not communicating.' : 'Generated from GeoTab telemetry thresholds.',
            ];
        }

        $maintenanceFaults = [];
        foreach ($vehicles as $vehicle) {
            foreach ((array) ($vehicle['recentFaults'] ?? []) as $fault) {
                $maintenanceFaults[] = [
                    'vehicle' => $vehicle['plate'],
                    'geotabId' => $vehicle['geotabId'],
                    'status' => $vehicle['status'],
                    ...$fault,
                ];
            }
        }
        usort($maintenanceFaults, fn (array $a, array $b) => strcmp((string) ($b['dateTime'] ?? ''), (string) ($a['dateTime'] ?? '')));

        $maintenanceDvir = array_values(array_filter(array_map(function (array $log) use ($deviceIndex): ?array {
            $deviceId = $this->idFromValue(data_get($log, 'device'));
            $device = $deviceIndex[$deviceId] ?? [];
            $vehicle = $this->plateForDevice($device);
            if ($vehicle === 'UNKNOWN') {
                return null;
            }

            return $this->formatDvirLog($log, $device);
        }, $dvirLogs)));
        usort($maintenanceDvir, fn (array $a, array $b) => strcmp((string) ($b['dateTime'] ?? ''), (string) ($a['dateTime'] ?? '')));

        $maintenanceWorkOrders = array_values(array_map(function (array $record, int $index): array {
            $sourceType = $this->normalizeWorkOrderSource((string) ($record['sourceType'] ?? 'service_threshold'));
            $sourceRecordId = (string) ($record['sourceRecordId'] ?? ('maintenance-alert-'.md5(json_encode($record))));

            return [
                'id' => 'WO-'.str_pad((string) ($index + 1), 4, '0', STR_PAD_LEFT),
                'workOrderId' => 'WO-'.str_pad((string) ($index + 1), 4, '0', STR_PAD_LEFT),
                'vehicle' => $record['vehicle'],
                'vehiclePlate' => $record['vehicle'],
                'vehicleGeotabId' => $record['geotabId'] ?? null,
                'title' => $record['type'],
                'description' => $record['description'],
                'status' => $record['status'],
                'statusLabel' => $this->workOrderStatusLabel((string) ($record['status'] ?? 'open')),
                'priority' => $record['priority'],
                'scheduledDate' => $record['date'],
                'cost' => $record['cost'],
                'sourceType' => $sourceType,
                'sourceLabel' => $this->workOrderSourceLabel($sourceType),
                'sourceRecordId' => $sourceRecordId,
                'sourceSummary' => $record['sourceSummary'] ?? $record['description'],
                'isNativeWorkOrder' => false,
                'isDerivedWorkOrder' => true,
                'isGeotabBacked' => $sourceType !== 'manual',
                'assignedTo' => 'Unassigned',
                'attachmentCount' => 0,
                'attachments' => [],
            ];
        }, $maintenance, array_keys($maintenance)));

        foreach (array_slice($maintenanceDvir, 0, 8) as $dvir) {
            $sourceRecordId = (string) ($dvir['id'] ?? $dvir['geotabId'] ?? substr(md5(json_encode($dvir)), 0, 12));
            $maintenanceWorkOrders[] = [
                'id' => 'DVIR-'.substr(md5(json_encode($dvir)), 0, 8),
                'workOrderId' => 'DVIR-'.substr(md5(json_encode($dvir)), 0, 8),
                'vehicle' => $dvir['vehicle'],
                'vehiclePlate' => $dvir['vehicle'],
                'vehicleGeotabId' => $dvir['geotabId'] ?? null,
                'title' => 'DVIR Inspection',
                'description' => $dvir['driverRemark'] !== '' ? $dvir['driverRemark'] : 'Driver inspection log synced from Geotab.',
                'status' => $dvir['isSafeToOperate'] ? 'scheduled' : 'in progress',
                'statusLabel' => $this->workOrderStatusLabel($dvir['isSafeToOperate'] ? 'open' : 'in_progress'),
                'priority' => $dvir['isSafeToOperate'] ? 'Medium' : 'High',
                'scheduledDate' => $dvir['displayDate'],
                'cost' => 'N/A',
                'sourceType' => 'geotab_dvir',
                'sourceLabel' => $this->workOrderSourceLabel('geotab_dvir'),
                'sourceRecordId' => $sourceRecordId,
                'sourceSummary' => 'Derived from GeoTab DVIR inspection evidence.',
                'isNativeWorkOrder' => false,
                'isDerivedWorkOrder' => true,
                'isGeotabBacked' => true,
                'assignedTo' => 'Unassigned',
                'attachmentCount' => 0,
                'attachments' => [],
            ];
        }

        foreach (array_slice($maintenanceFaults, 0, 12) as $fault) {
            $sourceRecordId = (string) ($fault['id'] ?? $fault['geotabId'] ?? $fault['faultCode'] ?? substr(md5(json_encode($fault)), 0, 12));
            $maintenanceWorkOrders[] = [
                'id' => 'FAULT-'.substr(md5(json_encode($fault)), 0, 8),
                'workOrderId' => 'FAULT-'.substr(md5(json_encode($fault)), 0, 8),
                'vehicle' => $fault['vehicle'] ?? 'Unknown',
                'vehiclePlate' => $fault['vehicle'] ?? 'Unknown',
                'vehicleGeotabId' => $fault['geotabId'] ?? null,
                'title' => 'Inspect '.$this->sanitizeText($fault['faultCode'] ?? $fault['code'] ?? 'GeoTab Fault', 'GeoTab Fault'),
                'description' => $this->sanitizeText($fault['description'] ?? $fault['failureMode'] ?? 'Diagnostic fault requires maintenance review.', 'Diagnostic fault requires maintenance review.'),
                'status' => 'open',
                'statusLabel' => $this->workOrderStatusLabel('open'),
                'priority' => $this->sanitizeText($fault['severity'] ?? 'High', 'High'),
                'scheduledDate' => $fault['displayDate'] ?? substr((string) ($fault['dateTime'] ?? now()->toIso8601String()), 0, 10),
                'cost' => 'N/A',
                'sourceType' => 'geotab_fault',
                'sourceLabel' => $this->workOrderSourceLabel('geotab_fault'),
                'sourceRecordId' => $sourceRecordId,
                'sourceSummary' => 'Derived from GeoTab FaultData.',
                'isNativeWorkOrder' => false,
                'isDerivedWorkOrder' => true,
                'isGeotabBacked' => true,
                'assignedTo' => 'Unassigned',
                'attachmentCount' => 0,
                'attachments' => [],
            ];
        }

        $maintenanceWorkOrders = $this->mergeNativeMaintenanceWorkOrders($maintenanceWorkOrders);
        $vehicles = $this->attachMaintenanceWorkOrdersToVehicles($vehicles, $maintenanceWorkOrders);

        $maintenanceMeasurements = array_values(array_map(function (array $vehicle): array {
            return [
                'vehicle' => $vehicle['plate'],
                'odometerKm' => (float) ($vehicle['odometerKm'] ?? 0),
                'engineHours' => (float) ($vehicle['engineHours'] ?? 0),
                'fuelLevelRatio' => (float) ($vehicle['fuelLevelRatio'] ?? 0),
                'isCommunicating' => $vehicle['isCommunicating'] ?? false,
                'healthScore' => $vehicle['healthScore'] ?? 100,
                'nextMaintenance' => $vehicle['nextMaintenance'] ?? 'N/A',
                'lastInspection' => $vehicle['lastInspection'] ?? 'N/A',
            ];
        }, $vehicles));

        $maintenance = $this->mergeMaintenanceHistory($maintenance, $vehicles);

        $maintenanceOverview = [
            'activeAlerts' => count($maintenance),
            'faults' => count($maintenanceFaults),
            'dvirReports' => count($maintenanceDvir),
            'workOrders' => count($maintenanceWorkOrders),
            'offlineAssets' => count(array_filter($vehicles, fn (array $vehicle): bool => ($vehicle['isCommunicating'] ?? false) !== true)),
        ];

        $driversView = [];
        $seenDrivers = [];
        foreach ($drivers as $driver) {
            $driverId = $this->idFromValue($driver);
            $driverName = $this->userDisplayName($driver);
            if ($driverName === '' || $driverName === 'UnknownDriver') {
                continue;
            }

            $statusRow = $this->findStatusByDriver($statusList, $driverId, $driverName);
            $driverKey = $driverId !== '' ? $driverId : $driverName;
            $stats = $tripStatsByDriver[$driverKey] ?? [];
            $currentVehiclePlate = $this->plateForDevice($deviceIndex[$this->idFromValue(data_get($statusRow, 'device'))] ?? []);
            $currentStatus = data_get($statusRow, 'isDriving') === true ? 'on trip' : 'available';
            $score = max(60, 100 - (int) (($stats['speedEvents'] ?? 0) * 2));

            $driversView[] = [
                'name' => $driverName,
                'driverId' => $driverId,
                'license' => (string) data_get($driver, 'licenseNumber', 'N/A'),
                'licenseExpiry' => 'N/A',
                'phone' => (string) data_get($driver, 'phoneNumber', 'N/A'),
                'email' => (string) data_get($driver, 'name', 'N/A'),
                'joinDate' => $this->displayShortDate($this->parseDate(data_get($driver, 'activeFrom'))),
                'status' => $currentStatus,
                'trips' => (int) ($stats['count'] ?? 0),
                'revenue' => $this->money((float) ($stats['revenue'] ?? 0)),
                'score' => $score,
                'delays' => 0,
                'assignedVehicle' => $currentVehiclePlate,
                'employeeNumber' => (string) data_get($driver, 'employeeNo', ''),
                'hosRuleSet' => $this->stringValue(data_get($driver, 'hosRuleSet')),
            ];
            $seenDrivers[$driverKey] = true;
        }

        foreach ($statusList as $status) {
            $driver = data_get($status, 'driver');
            $driverName = $this->userDisplayName($driver);
            $driverId = $this->idFromValue($driver);
            $driverKey = $driverId !== '' ? $driverId : $driverName;
            if ($driverName === '' || isset($seenDrivers[$driverKey])) {
                continue;
            }

            $driversView[] = [
                'name' => $driverName,
                'driverId' => $driverId,
                'license' => 'N/A',
                'licenseExpiry' => 'N/A',
                'phone' => 'N/A',
                'email' => 'N/A',
                'joinDate' => 'N/A',
                'status' => data_get($status, 'isDriving') === true ? 'on trip' : 'available',
                'trips' => (int) (($tripStatsByDriver[$driverKey]['count'] ?? 0)),
                'revenue' => $this->money((float) (($tripStatsByDriver[$driverKey]['revenue'] ?? 0))),
                'score' => max(60, 100 - (int) ((($tripStatsByDriver[$driverKey]['speedEvents'] ?? 0) * 2))),
                'delays' => 0,
                'assignedVehicle' => $this->plateForDevice($deviceIndex[$this->idFromValue(data_get($status, 'device'))] ?? []),
                'employeeNumber' => '',
                'hosRuleSet' => 'N/A',
            ];
        }

        $driversView = $this->mergeManualDrivers($driversView);
        usort($driversView, fn (array $a, array $b) => strcmp((string) ($a['name'] ?? ''), (string) ($b['name'] ?? '')));

        $plannedRouteTrips = $this->plannedTripsFromRoutes($routesView, $deviceIndex);
        $tripsView = array_merge($plannedRouteTrips, $liveTrips, $historicalTrips);
        usort($tripsView, fn (array $a, array $b) => strcmp($b['sortAt'], $a['sortAt']));
        $tripsView = $this->applyTripWorkflow($tripsView);
        $tripsView = array_values(array_map(function (array $trip): array {
            unset($trip['sortAt']);

            return $trip;
        }, $tripsView));

        [$vehicles, $driversView] = $this->applyTripAssignments(
            $tripsView,
            $vehicles,
            $driversView,
        );

        $billings = array_values(array_map(function (array $trip): array {
            return $this->itemizedInvoiceForTrip($trip);
        }, array_filter($tripsView, function (array $trip): bool {
            return $this->tripBillableForEstimate($trip);
        })));

        $billingOverview = [
            'totalBilled' => round(array_sum(array_map(fn (array $invoice): float => $this->parseMoney($invoice['amount'] ?? 0), $billings)), 2),
            'totalPaid' => round(array_sum(array_map(function (array $invoice): float {
                return (($invoice['status'] ?? '') === 'paid') ? $this->parseMoney($invoice['amount'] ?? 0) : 0.0;
            }, $billings)), 2),
            'totalSent' => round(array_sum(array_map(function (array $invoice): float {
                return in_array(($invoice['status'] ?? ''), ['sent', 'issued'], true) ? $this->parseMoney($invoice['amount'] ?? 0) : 0.0;
            }, $billings)), 2),
            'totalOverdue' => round(array_sum(array_map(function (array $invoice): float {
                return (($invoice['status'] ?? '') === 'overdue') ? $this->parseMoney($invoice['amount'] ?? 0) : 0.0;
            }, $billings)), 2),
            'invoiceCount' => count($billings),
        ] + $this->billingIntelligenceOverview($billings);

        $soa = $this->buildStatementOfAccounts($billings);
        $clients = $this->loadFleetClients([
            'trips' => $tripsView,
            'billings' => $billings,
            'soa' => $soa,
        ]);

        $unmatchedRoutes = $this->buildUnmatchedRoutesReport($historicalTrips, $liveTrips);
        $driverCongregation = $this->buildDriverCongregationReport($statusList, $zones, $deviceIndex);

        $telemetryAssets = [];
        $temperatureAssets = [];
        foreach ($vehicles as $vehicle) {
            $deviceId = (string) $vehicle['geotabId'];
            $telemetry = $telemetryByDevice[$deviceId] ?? $this->emptyTelemetryEntry($definitions);
            $alerts = $this->telemetryAlerts($telemetry, $vehicle);
            $telemetryAssets[] = [
                'geotabId' => $deviceId,
                'vehicle' => $vehicle['plate'],
                'driver' => $vehicle['driver'],
                'status' => $vehicle['status'],
                'isCommunicating' => $vehicle['isCommunicating'],
                'lastUpdated' => $vehicle['lastUpdated'],
                'diagnostics' => $telemetry,
                'alertCount' => count(array_filter($alerts, fn (bool $value): bool => $value)),
                'alerts' => $alerts,
                'routeName' => $vehicle['assignedRoute'] ?? null,
                'routeStops' => $vehicle['routeStops'] ?? [],
                'currentZone' => $vehicle['currentZone'] ?? null,
                'destinationZone' => $vehicle['destinationZone'] ?? null,
                'arrivalState' => $vehicle['arrivalState'] ?? null,
                'isElectric' => $vehicle['isElectric'] ?? false,
                'coldChainCapable' => $vehicle['coldChainCapable'] ?? false,
                'recentDriverChanges' => $vehicle['recentDriverChanges'] ?? [],
                'shipments' => $vehicle['shipments'] ?? [],
                'ioxAddOns' => $vehicle['ioxAddOns'] ?? [],
                'healthStatus' => $vehicle['healthStatus'] ?? 'healthy',
                'healthScore' => $vehicle['healthScore'] ?? 100,
                'engineHours' => $vehicle['engineHours'] ?? null,
                'odometerKm' => $vehicle['odometerKm'] ?? null,
                'fuelLevelRatio' => $vehicle['fuelLevelRatio'] ?? null,
                'fuelCapacity' => $vehicle['fuelCapacity'] ?? null,
                'recentFaults' => $vehicle['recentFaults'] ?? [],
                'recentExceptions' => $vehicle['recentExceptions'] ?? [],
            ];

            $temperatureSensorInstalled = $this->diagnosticHasValue($telemetry['engineCoolantTemperature'] ?? null)
                || $this->diagnosticHasValue($telemetry['outsideTemperature'] ?? null)
                || $this->diagnosticHasValue($telemetry['relativeHumidity'] ?? null)
                || $this->diagnosticHasValue($telemetry['cargoTemperatureZone1'] ?? null)
                || $this->diagnosticHasValue($telemetry['cargoTemperatureZone2'] ?? null)
                || $this->diagnosticHasValue($telemetry['cargoTemperatureZone3'] ?? null)
                || $this->diagnosticHasValue($telemetry['reeferTemperatureZone1'] ?? null)
                || $this->diagnosticHasValue($telemetry['reeferTemperatureZone2'] ?? null)
                || $this->diagnosticHasValue($telemetry['reeferTemperatureZone3'] ?? null)
                || $this->diagnosticHasValue($telemetry['reeferTemperatureZone4'] ?? null);

            $temperatureAssets[] = [
                'geotabId' => $deviceId,
                'vehicle' => $vehicle['plate'],
                'sensorInstalled' => $temperatureSensorInstalled,
                'sensorStatus' => $temperatureSensorInstalled ? 'OK' : 'No sensor installed',
                'engineCoolantTemperature' => $telemetry['engineCoolantTemperature'] ?? null,
                'outsideTemperature' => $telemetry['outsideTemperature'] ?? null,
                'relativeHumidity' => $telemetry['relativeHumidity'] ?? null,
                'engineCoolingFanSpeed' => $telemetry['engineCoolingFanSpeed'] ?? null,
                'cargoTemperatures' => array_values(array_filter([
                    $telemetry['cargoTemperatureZone1'] ?? null,
                    $telemetry['cargoTemperatureZone2'] ?? null,
                    $telemetry['cargoTemperatureZone3'] ?? null,
                ], fn (?array $entry): bool => $this->diagnosticHasValue($entry))),
                'reeferTemperatures' => array_values(array_filter([
                    $telemetry['reeferTemperatureZone1'] ?? null,
                    $telemetry['reeferTemperatureZone2'] ?? null,
                    $telemetry['reeferTemperatureZone3'] ?? null,
                    $telemetry['reeferTemperatureZone4'] ?? null,
                ], fn (?array $entry): bool => $this->diagnosticHasValue($entry))),
                'alerts' => [
                    'engineHot' => $alerts['engineHot'],
                    'coldChainVariance' => $alerts['coldChainVariance'],
                    'humidityAlert' => $alerts['humidityAlert'],
                    'coolingAlert' => $alerts['coolingAlert'],
                ],
            ];
        }

        $usageByVehicle = [];
        foreach ($vehicles as $vehicle) {
            $deviceId = (string) $vehicle['geotabId'];
            $usage = $fuelUsageByDevice[$deviceId] ?? [];
            $fillStats = $fillUpStatsByDevice[$deviceId] ?? [];
            $telemetry = $telemetryByDevice[$deviceId] ?? $this->emptyTelemetryEntry($definitions);
            $fuelUsed = round((float) ($usage['fuelUsedLiters'] ?? 0), 2);
            $distanceKm = round((float) ($vehicle['distanceKm14d'] ?? 0), 2);
            $fuelUseEstimated = false;
            if ($fuelUsed <= 0) {
                $economy = (float) ($vehicle['fuelEconomyKmPerLiter'] ?? 0);
                $fuelUsed = $economy > 0 && $distanceKm > 0
                    ? round($distanceKm / $economy, 2)
                    : round(max(6.0, ((float) ($vehicle['odometerKm'] ?? 0) % 220) / 8), 2);
                $fuelUseEstimated = true;
            }
            $idleFuel = round((float) ($usage['idlingFuelUsedLiters'] ?? 0), 2);
            if ($idleFuel <= 0 && $fuelUsed > 0) {
                $idleFuel = round($fuelUsed * (0.08 + (($this->stableVehicleSeed(['id' => $deviceId]) % 6) / 100)), 2);
            }
            $consumptionRate = $distanceKm > 0 ? round(($fuelUsed / max($distanceKm, 1)) * 100, 2) : null;
            $estimatedFuelCost = round($fuelUsed * (float) ($fuelPriceSettings['dieselPricePerLiter'] ?? 0), 2);
            $costPerKm = $distanceKm > 0 ? round($estimatedFuelCost / $distanceKm, 2) : null;
            $abnormal = $consumptionRate !== null && $consumptionRate > 45;

            $usageByVehicle[] = [
                'geotabId' => $deviceId,
                'vehicle' => $vehicle['plate'],
                'fuelUsedLiters' => $fuelUsed,
                'idlingFuelUsedLiters' => $idleFuel,
                'energyUsedKwh' => round((float) ($usage['energyUsedKwh'] ?? 0), 2),
                'idlingEnergyUsedKwh' => round((float) ($usage['idlingEnergyUsedKwh'] ?? 0), 2),
                'distanceKm' => $distanceKm,
                'consumptionLitersPer100Km' => $consumptionRate,
                'estimatedFuelCost' => $estimatedFuelCost,
                'estimatedFuelCostLabel' => $this->money($estimatedFuelCost),
                'costPerKm' => $costPerKm,
                'costPerKmLabel' => $costPerKm !== null ? $this->money($costPerKm).'/km' : 'N/A',
                'abnormalConsumption' => $abnormal,
                'inefficient' => $abnormal || ($costPerKm !== null && $costPerKm > 35),
                'lastFillUpAt' => $fillStats['lastEventAt'] ?? null,
                'fillUpEvents' => (int) ($fillStats['events'] ?? 0),
                'fuelLevel' => $telemetry['fuelLevel'] ?? null,
                'fuelTankCapacity' => $telemetry['fuelTankCapacity'] ?? null,
                'fuelLevelRatio' => $vehicle['fuelLevelRatio'] ?? null,
                'fuelCapacity' => $vehicle['fuelCapacity'] ?? null,
                'estimated' => $fuelUseEstimated,
            ];
        }

        usort($usageByVehicle, fn (array $a, array $b) => ((float) ($b['fuelUsedLiters'] ?? 0)) <=> ((float) ($a['fuelUsedLiters'] ?? 0)));
        $existingFuelVehicles = [];
        foreach ([...$fillUpEvents, ...$fuelTransactionEvents] as $event) {
            $vehicleKey = strtoupper(trim((string) ($event['vehicle'] ?? $event['vehiclePlate'] ?? '')));
            if ($vehicleKey !== '') {
                $existingFuelVehicles[$vehicleKey] = true;
            }
        }
        foreach ($usageByVehicle as $row) {
            $vehicleKey = strtoupper(trim((string) ($row['vehicle'] ?? '')));
            if ($vehicleKey === '' || isset($existingFuelVehicles[$vehicleKey]) || (float) ($row['fuelUsedLiters'] ?? 0) <= 0) {
                continue;
            }

            $fillUpEvents[] = $this->withFuelEstimate([
                'id' => 'fuel-estimate-'.$row['geotabId'].'-'.now()->format('Ymd'),
                'sourceRecordId' => 'fuel-estimate-'.$row['geotabId'].'-'.now()->format('Ymd'),
                'vehicle' => $row['vehicle'],
                'vehicleGeotabId' => $row['geotabId'],
                'driver' => 'Unassigned',
                'station' => 'Pioneer fuel estimate',
                'stationName' => 'Pioneer fuel estimate',
                'date' => now()->format('M j, Y'),
                'dateTime' => now()->toIso8601String(),
                'volumeLiters' => round((float) ($row['fuelUsedLiters'] ?? 0), 2),
                'liters' => round((float) ($row['fuelUsedLiters'] ?? 0), 2),
                'cost' => (float) ($row['estimatedFuelCost'] ?? 0),
                'totalCost' => (float) ($row['estimatedFuelCost'] ?? 0),
                'fuelType' => 'diesel',
                'source' => 'Predictive estimate',
                'reviewStatus' => 'needs_review',
                'confidence' => 'likely',
                'notes' => 'Estimated from GeoTab distance, fuel economy, and configured fuel price.',
            ], $fuelPriceSettings);
            $existingFuelVehicles[$vehicleKey] = true;
        }

        $notifications = [];
        foreach (array_slice($liveTrips, 0, 3) as $trip) {
            $notifications[] = [
                'id' => 'trip-'.$trip['tripId'],
                'title' => 'Live Trip Active',
                'message' => $trip['vehicle'].' is currently moving with '.($trip['driver'] !== '' ? $trip['driver'] : 'an unassigned driver').'.',
                'time' => $trip['date'],
                'timestamp' => now()->toIso8601String(),
                'category' => 'trip',
                'isRead' => false,
            ];
        }
        foreach (array_slice($maintenance, 0, 2) as $record) {
            $notifications[] = [
                'id' => 'maintenance-'.$record['vehicle'],
                'title' => $record['type'],
                'message' => $record['vehicle'].': '.$record['description'],
                'time' => $record['date'],
                'timestamp' => Carbon::parse($record['date'])->toIso8601String(),
                'category' => 'maintenance',
                'isRead' => false,
            ];
        }
        foreach (array_slice($fillUpEvents, 0, 2) as $event) {
            $notifications[] = [
                'id' => 'fuel-'.$event['vehicle'].'-'.substr((string) ($event['dateTime'] ?? ''), 0, 19),
                'title' => 'Fuel Event Synced',
                'message' => $event['vehicle'].' recorded '.$event['volumeLiters'].' L at '.$event['costLabel'].'.',
                'time' => $event['date'],
                'timestamp' => $event['dateTime'] ?? now()->toIso8601String(),
                'category' => 'fuel',
                'isRead' => false,
            ];
        }
        $notifications = $this->mergeStoredNotifications($notifications);
        $notifications = $this->applyNotificationState($notifications);

        $telemetryOverview = [
            'assetCount' => count($telemetryAssets),
            'communicatingAssets' => count(array_filter($vehicles, fn (array $vehicle): bool => ($vehicle['isCommunicating'] ?? false) === true)),
            'offlineAssets' => count(array_filter($vehicles, fn (array $vehicle): bool => ($vehicle['isCommunicating'] ?? false) !== true)),
            'lowFuelAssets' => count(array_filter($telemetryAssets, fn (array $asset): bool => ($asset['alerts']['lowFuel'] ?? false) === true)),
            'engineHotAssets' => count(array_filter($telemetryAssets, fn (array $asset): bool => ($asset['alerts']['engineHot'] ?? false) === true)),
            'coldChainVarianceAssets' => count(array_filter($telemetryAssets, fn (array $asset): bool => ($asset['alerts']['coldChainVariance'] ?? false) === true)),
            'humidityAlertAssets' => count(array_filter($telemetryAssets, fn (array $asset): bool => ($asset['alerts']['humidityAlert'] ?? false) === true)),
            'coolingAlertAssets' => count(array_filter($telemetryAssets, fn (array $asset): bool => ($asset['alerts']['coolingAlert'] ?? false) === true)),
            'coverage' => $this->diagnosticCoverage($telemetryAssets, $definitions),
            'assets' => $telemetryAssets,
        ];

        $fuelPayload = [
            'totals' => [
                'totalSpend' => round(array_sum(array_map(fn (array $event): float => (float) ($event['cost'] ?? 0), $fillUpEvents)), 2),
                'totalLiters' => round(array_sum(array_map(fn (array $event): float => (float) ($event['volumeLiters'] ?? 0), $fillUpEvents)), 2),
                'avgPricePerLiter' => $this->safeDivide(
                    array_sum(array_map(fn (array $event): float => (float) ($event['cost'] ?? 0), $fillUpEvents)),
                    array_sum(array_map(fn (array $event): float => (float) ($event['volumeLiters'] ?? 0), $fillUpEvents)),
                ),
                'fuelUsedLiters' => round(array_sum(array_map(fn (array $row): float => (float) ($row['fuelUsedLiters'] ?? 0), $usageByVehicle)), 2),
                'idlingFuelUsedLiters' => round(array_sum(array_map(fn (array $row): float => (float) ($row['idlingFuelUsedLiters'] ?? 0), $usageByVehicle)), 2),
                'energyUsedKwh' => round(array_sum(array_map(fn (array $row): float => (float) ($row['energyUsedKwh'] ?? 0), $usageByVehicle)), 2),
                'chargingSessions' => count($chargeEventRows),
                'vehiclesReporting' => count(array_filter($usageByVehicle, fn (array $row): bool => ((float) ($row['fuelUsedLiters'] ?? 0)) > 0)),
            ],
            'events' => $fillUpEvents,
            'usageByVehicle' => $usageByVehicle,
            'transactions' => $fuelTransactionEvents,
            'chargeEvents' => $chargeEventRows,
            'priceSettings' => $fuelPriceSettings,
        ];

        $temperaturePayload = [
            'overview' => [
                'assetsReporting' => count(array_filter($temperatureAssets, function (array $asset): bool {
                    return $this->diagnosticHasValue(is_array($asset['engineCoolantTemperature'] ?? null) ? $asset['engineCoolantTemperature'] : null)
                        || $this->diagnosticHasValue(is_array($asset['outsideTemperature'] ?? null) ? $asset['outsideTemperature'] : null)
                        || $asset['cargoTemperatures'] !== []
                        || $asset['reeferTemperatures'] !== [];
                })),
                'engineHotAssets' => $telemetryOverview['engineHotAssets'],
                'coldChainVarianceAssets' => $telemetryOverview['coldChainVarianceAssets'],
                'humidityAlertAssets' => $telemetryOverview['humidityAlertAssets'],
                'coolingAlertAssets' => $telemetryOverview['coolingAlertAssets'],
            ],
            'assets' => $temperatureAssets,
        ];

        $dashboardInsights = $this->dashboardInsights(
            $tripsView,
            $vehicles,
            $driversView,
            $billings,
            $telemetryOverview,
        );

        $dashboard = [
            'dateLabel' => now()->format('l, F j, Y'),
            'stats' => [
                [
                    'title' => 'Active Vehicles',
                    'value' => (string) count(array_filter($vehicles, function (array $vehicle): bool {
                        $status = strtolower((string) ($vehicle['status'] ?? ''));

                        return ! in_array($status, ['maintenance', 'inactive', 'deactivated'], true);
                    })),
                    'subtitle' => 'Live Geotab assets',
                    'icon' => 'truck',
                ],
                [
                    'title' => 'Active Drivers',
                    'value' => (string) count(array_filter($driversView, fn (array $driver) => ($driver['status'] ?? '') === 'on trip')),
                    'subtitle' => 'Currently moving',
                    'icon' => 'driver',
                ],
                [
                    'title' => 'Trips Recent',
                    'value' => (string) count($tripsView),
                    'subtitle' => 'Live plus history',
                    'icon' => 'trip',
                ],
                [
                    'title' => 'Fuel Events',
                    'value' => (string) count($fillUpEvents),
                    'subtitle' => 'Last 30 days',
                    'icon' => 'fuel',
                ],
                [
                    'title' => 'Telemetry Alerts',
                    'value' => (string) (
                        $telemetryOverview['lowFuelAssets']
                        + $telemetryOverview['engineHotAssets']
                        + $telemetryOverview['coldChainVarianceAssets']
                        + $telemetryOverview['humidityAlertAssets']
                        + $telemetryOverview['coolingAlertAssets']
                    ),
                    'subtitle' => 'Fuel, temp, connectivity',
                    'icon' => 'warning',
                ],
            ],
            'maintenance' => $maintenance,
            'totalDistanceKm' => round(array_sum(array_map(fn (array $trip) => (float) ($trip['distanceKm'] ?? 0), $historicalTrips)), 2),
            'totalFuelUsedLiters' => $fuelPayload['totals']['fuelUsedLiters'],
            'totalFuelCost' => $fuelPayload['totals']['totalSpend'],
            'liveTrips' => count(array_filter($tripsView, fn (array $trip): bool => in_array(strtolower((string) ($trip['status'] ?? '')), ['dispatched', 'in progress', 'on trip', 'pending_approval'], true))),
            'completedTrips' => count(array_filter($tripsView, fn (array $trip): bool => strtolower((string) ($trip['status'] ?? '')) === 'completed')),
            'maintenanceDue' => count($maintenance),
            'insights' => $dashboardInsights,
            'tripsThisWeek' => $dashboardInsights['tripsThisWeek'],
            'fleetUtilization' => $dashboardInsights['fleetUtilization'],
            'topActiveVehicles' => $dashboardInsights['topActiveVehicles'],
            'recentRevenueSummary' => $dashboardInsights['recentRevenueSummary'],
            'humidityAlertCount' => $dashboardInsights['humidityAlertCount'],
        ];

        return [
            'vehicles' => $vehicles,
            'drivers' => $driversView,
            'trips' => $tripsView,
            'clients' => $clients,
            'routes' => $routesView,
            'zones' => $zonesView,
            'billings' => $billings,
            'billingOverview' => $billingOverview,
            'soa' => $soa,
            'maintenance' => $maintenance,
            'maintenanceOverview' => $maintenanceOverview,
            'maintenanceFaults' => $maintenanceFaults,
            'maintenanceDvir' => $maintenanceDvir,
            'maintenanceWorkOrders' => $maintenanceWorkOrders,
            'maintenanceMeasurements' => $maintenanceMeasurements,
            'fuel' => $fuelPayload,
            'temperature' => $temperaturePayload,
            'telemetry' => $telemetryOverview,
            'compliance' => $compliance,
            'notifications' => $notifications,
            'reports' => [
                'unmatchedRoutes' => $unmatchedRoutes,
                'driverCongregation' => $driverCongregation,
            ],
            'dashboard' => $dashboard,
            'lastSyncedAt' => now()->toIso8601String(),
        ];
    }

    private function emptySnapshot(): array
    {
        return [
            'vehicles' => [],
            'drivers' => [],
            'trips' => [],
            'clients' => [],
            'routes' => [],
            'zones' => [],
            'billings' => [],
            'billingOverview' => [
                'totalBilled' => 0,
                'totalPaid' => 0,
                'totalSent' => 0,
                'totalOverdue' => 0,
                'invoiceCount' => 0,
            ] + $this->billingIntelligenceOverview([]),
            'soa' => [
                'overview' => [
                    'clients' => 0,
                    'totalOutstanding' => 0,
                    'totalPaid' => 0,
                    'totalOverdue' => 0,
                ],
                'clients' => [],
            ],
            'maintenance' => [],
            'maintenanceOverview' => [
                'activeAlerts' => 0,
                'faults' => 0,
                'dvirReports' => 0,
                'workOrders' => 0,
                'offlineAssets' => 0,
            ],
            'maintenanceFaults' => [],
            'maintenanceDvir' => [],
            'maintenanceWorkOrders' => [],
            'maintenanceMeasurements' => [],
            'fuel' => [
                'totals' => [
                    'totalSpend' => 0,
                    'totalLiters' => 0,
                    'avgPricePerLiter' => 0,
                    'fuelUsedLiters' => 0,
                    'idlingFuelUsedLiters' => 0,
                    'energyUsedKwh' => 0,
                    'chargingSessions' => 0,
                    'vehiclesReporting' => 0,
                ],
                'events' => [],
                'usageByVehicle' => [],
                'transactions' => [],
                'chargeEvents' => [],
                'priceSettings' => $this->fuelPriceSettingsPayload(),
            ],
            'temperature' => [
                'overview' => [
                    'assetsReporting' => 0,
                    'engineHotAssets' => 0,
                    'coldChainVarianceAssets' => 0,
                ],
                'assets' => [],
            ],
            'telemetry' => [
                'assetCount' => 0,
                'communicatingAssets' => 0,
                'offlineAssets' => 0,
                'lowFuelAssets' => 0,
                'engineHotAssets' => 0,
                'coldChainVarianceAssets' => 0,
                'coverage' => [],
                'assets' => [],
            ],
            'compliance' => [],
            'notifications' => [],
            'reports' => [
                'unmatchedRoutes' => [],
                'driverCongregation' => [],
            ],
            'dashboard' => [
                'dateLabel' => now()->format('l, F j, Y'),
                'stats' => [],
                'maintenance' => [],
                'totalDistanceKm' => 0,
                'totalFuelUsedLiters' => 0,
                'totalFuelCost' => 0,
                'liveTrips' => 0,
                'completedTrips' => 0,
                'maintenanceDue' => 0,
                'insights' => [
                    'tripsThisWeek' => [],
                    'fleetUtilization' => [
                        'activeVehiclesToday' => 0,
                        'totalVehicles' => 0,
                        'rate' => 0,
                    ],
                    'topActiveVehicles' => [],
                    'recentRevenueSummary' => [
                        'thisWeek' => 0,
                        'lastWeek' => 0,
                        'trend' => 'flat',
                    ],
                    'humidityAlertCount' => 0,
                ],
            ],
            'lastSyncedAt' => now()->toIso8601String(),
        ];
    }

    private function diagnosticDefinitions(): array
    {
        return [
            'ignitionOn' => ['label' => 'Ignition', 'unit' => '', 'type' => 'boolean', 'candidates' => ['Ignition', 'Ignition status', 'Ignition on']],
            'fuelLevel' => ['label' => 'Fuel Level', 'unit' => 'L', 'type' => 'number', 'candidates' => ['DiagnosticFuelUnitsId', 'Fuel level']],
            'fuelTankCapacity' => ['label' => 'Fuel Tank Capacity', 'unit' => 'L', 'type' => 'number', 'candidates' => ['Fuel tank capacity']],
            'totalFuelUsed' => ['label' => 'Total Fuel Used', 'unit' => 'L', 'type' => 'number', 'candidates' => ['DiagnosticDeviceTotalFuelId', 'Total fuel used (since telematics device install)', 'Total fuel used']],
            'totalIdleFuelUsed' => ['label' => 'Idle Fuel Used', 'unit' => 'L', 'type' => 'number', 'candidates' => ['DiagnosticDeviceTotalIdleFuelId', 'Total fuel used while idling (since telematics device install)', 'Total idle fuel used']],
            'engineCoolantTemperature' => ['label' => 'Engine Coolant Temperature', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Engine coolant temperature', 'Coolant temperature']],
            'outsideTemperature' => ['label' => 'Outside Temperature', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Outside temperature']],
            'cargoTemperatureZone1' => ['label' => 'Cargo Temp Zone 1', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Cargo temperature zone 1']],
            'cargoTemperatureZone2' => ['label' => 'Cargo Temp Zone 2', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Cargo temperature zone 2']],
            'cargoTemperatureZone3' => ['label' => 'Cargo Temp Zone 3', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Cargo temperature zone 3']],
            'reeferTemperatureZone1' => ['label' => 'Reefer Temp Zone 1', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Reefer temperature zone 1']],
            'reeferTemperatureZone2' => ['label' => 'Reefer Temp Zone 2', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Reefer temperature zone 2']],
            'reeferTemperatureZone3' => ['label' => 'Reefer Temp Zone 3', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Reefer temperature zone 3']],
            'reeferTemperatureZone4' => ['label' => 'Reefer Temp Zone 4', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Reefer temperature zone 4']],
            'relativeHumidity' => ['label' => 'Relative Humidity', 'unit' => '%', 'type' => 'percent', 'candidates' => ['Relative humidity', 'IOX Works relative humidity']],
            'engineCoolingFanSpeed' => ['label' => 'Engine Cooling Fan Speed', 'unit' => 'rpm', 'type' => 'number', 'candidates' => ['Engine cooling fan speed']],
            'coolantLevel' => ['label' => 'Coolant Level', 'unit' => '%', 'type' => 'percent', 'candidates' => ['Coolant level']],
            'engineOilTemperature' => ['label' => 'Engine Oil Temperature', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Engine oil temperature']],
            'transmissionOilTemperature' => ['label' => 'Transmission Oil Temperature', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Engine transmission oil temperature', 'Transmission oil temperature']],
            'batteryVoltage' => ['label' => 'Battery Voltage', 'unit' => 'V', 'type' => 'number', 'candidates' => ['Battery voltage']],
            'batteryTemperature' => ['label' => 'Battery Temperature', 'unit' => 'C', 'type' => 'temperature', 'candidates' => ['Battery temperature']],
            'engineHours' => ['label' => 'Engine Hours', 'unit' => 'h', 'type' => 'seconds_to_hours', 'candidates' => ['DiagnosticEngineHoursAdjustmentId', 'DiagnosticEngineHoursId', 'Engine hours', 'Engine hours adjustment', 'Engine on time']],
            'rawEngineHours' => ['label' => 'Raw Engine Hours', 'unit' => 'h', 'type' => 'seconds_to_hours', 'candidates' => ['DiagnosticRawEngineHoursId', 'Raw engine hours']],
            'rawOdometer' => ['label' => 'Raw Odometer', 'unit' => 'km', 'type' => 'meters_to_km', 'candidates' => ['DiagnosticRawOdometerId', 'DiagnosticOdometerId', 'Raw odometer', 'Odometer', 'Odometer adjustment']],
        ];
    }

    private function resolvedDiagnostics(): array
    {
        $lookupMap = [];
        foreach ($this->diagnosticDefinitions() as $alias => $definition) {
            $lookupMap[$alias] = $definition['candidates'];
        }

        return $this->safeGet(fn () => $this->geotab->resolveDiagnostics($lookupMap));
    }

    private function buildTelemetryEntry(array $status, array $definitions, array $diagnosticIdToAlias): array
    {
        $telemetry = $this->emptyTelemetryEntry($definitions);
        $statusDataRows = data_get($status, 'statusData', []);

        if (! is_array($statusDataRows)) {
            return $telemetry;
        }

        foreach ($statusDataRows as $row) {
            $diagnosticId = $this->idFromValue(data_get($row, 'diagnostic'));
            $alias = $diagnosticIdToAlias[$diagnosticId] ?? null;
            if ($alias === null || ! isset($definitions[$alias])) {
                continue;
            }

            $definition = $definitions[$alias];
            $value = $this->normalizeDiagnosticValue((string) ($definition['type'] ?? ''), data_get($row, 'data'));

            $telemetry[$alias] = [
                'label' => $definition['label'],
                'unit' => $definition['unit'],
                'supported' => $value !== null,
                'value' => $value,
                'displayValue' => $value === null
                    ? 'Unavailable'
                    : $this->formatDiagnosticValue($value, (string) ($definition['unit'] ?? '')),
                'timestamp' => data_get($row, 'dateTime'),
            ];
        }

        return $telemetry;
    }

    private function hydrateTemperatureTelemetryFromStatusData(
        array $telemetryByDevice,
        array $resolvedDiagnostics,
        array $definitions,
    ): array {
        $from = now()->subHours(24)->utc()->toIso8601String();
        $to = now()->utc()->toIso8601String();

        foreach ($this->temperatureWatchlistDiagnosticAliases() as $alias) {
            $diagnosticId = (string) data_get($resolvedDiagnostics, $alias.'.id', '');
            if ($diagnosticId === '' || ! isset($definitions[$alias])) {
                continue;
            }

            $rows = $this->safeGet(
                fn (): array => $this->geotab->getEntities('StatusData', [
                    'diagnosticSearch' => ['id' => $diagnosticId],
                    'fromDate' => $from,
                    'toDate' => $to,
                ], 500),
                ['stage' => 'temperature_status_data', 'alias' => $alias],
            );

            foreach ($rows as $row) {
                if (! is_array($row)) {
                    continue;
                }

                $deviceId = $this->idFromValue(data_get($row, 'device'));
                if ($deviceId === '') {
                    continue;
                }

                $entry = $this->statusDataTelemetryEntry($row, $definitions[$alias]);
                if ($entry === null) {
                    continue;
                }

                $telemetry = is_array($telemetryByDevice[$deviceId] ?? null)
                    ? $telemetryByDevice[$deviceId]
                    : $this->emptyTelemetryEntry($definitions);
                $telemetryByDevice[$deviceId] = $this->mergeTelemetryStatusDataEntry($telemetry, $alias, $entry);
            }

            foreach (array_keys($telemetryByDevice) as $deviceId) {
                if ((string) $deviceId === '' || $this->diagnosticHasValue($telemetryByDevice[$deviceId][$alias] ?? null)) {
                    continue;
                }

                $deviceRows = $this->safeGet(
                    fn (): array => $this->geotab->getEntities('StatusData', [
                        'deviceSearch' => ['id' => (string) $deviceId],
                        'diagnosticSearch' => ['id' => $diagnosticId],
                        'fromDate' => $from,
                        'toDate' => $to,
                    ], 100),
                    ['stage' => 'latest_status_data_device_missing', 'alias' => $alias, 'deviceId' => (string) $deviceId],
                );

                foreach ($deviceRows as $row) {
                    if (! is_array($row)) {
                        continue;
                    }

                    $entry = $this->statusDataTelemetryEntry($row, $definitions[$alias]);
                    if ($entry === null) {
                        continue;
                    }

                    $telemetry = is_array($telemetryByDevice[$deviceId] ?? null)
                        ? $telemetryByDevice[$deviceId]
                        : $this->emptyTelemetryEntry($definitions);
                    $telemetryByDevice[$deviceId] = $this->mergeTelemetryStatusDataEntry($telemetry, $alias, $entry);
                }
            }
        }

        return $telemetryByDevice;
    }

    private function hydrateLatestTelemetryFromStatusData(
        array $telemetryByDevice,
        array $resolvedDiagnostics,
        array $definitions,
        array $aliases,
    ): array {
        $from = now()->subHours(12)->utc()->toIso8601String();
        $to = now()->utc()->toIso8601String();

        foreach ($aliases as $alias) {
            $diagnosticId = (string) data_get($resolvedDiagnostics, $alias.'.id', '');
            if ($diagnosticId === '' || ! isset($definitions[$alias])) {
                continue;
            }

            $rows = $this->safeGet(
                fn (): array => $this->geotab->getEntities('StatusData', [
                    'diagnosticSearch' => ['id' => $diagnosticId],
                    'fromDate' => $from,
                    'toDate' => $to,
                ], 5000),
                ['stage' => 'latest_status_data', 'alias' => $alias],
            );

            if ($rows === [] && in_array($alias, ['engineHours', 'rawEngineHours'], true)) {
                foreach (array_keys($telemetryByDevice) as $deviceId) {
                    if ((string) $deviceId === '') {
                        continue;
                    }

                    $rows = [
                        ...$rows,
                        ...$this->safeGet(
                            fn (): array => $this->geotab->getEntities('StatusData', [
                                'deviceSearch' => ['id' => (string) $deviceId],
                                'diagnosticSearch' => ['id' => $diagnosticId],
                                'fromDate' => $from,
                                'toDate' => $to,
                            ], 100),
                            ['stage' => 'latest_status_data_device', 'alias' => $alias, 'deviceId' => (string) $deviceId],
                        ),
                    ];
                }
            }

            foreach ($rows as $row) {
                if (! is_array($row)) {
                    continue;
                }

                $deviceId = $this->idFromValue(data_get($row, 'device'));
                if ($deviceId === '') {
                    continue;
                }

                $entry = $this->statusDataTelemetryEntry($row, $definitions[$alias]);
                if ($entry === null) {
                    continue;
                }

                $telemetry = is_array($telemetryByDevice[$deviceId] ?? null)
                    ? $telemetryByDevice[$deviceId]
                    : $this->emptyTelemetryEntry($definitions);
                $telemetryByDevice[$deviceId] = $this->mergeTelemetryStatusDataEntry($telemetry, $alias, $entry);
            }
        }

        return $telemetryByDevice;
    }

    private function temperatureWatchlistDiagnosticAliases(): array
    {
        return [
            'engineCoolantTemperature',
            'outsideTemperature',
            'relativeHumidity',
            'cargoTemperatureZone1',
            'cargoTemperatureZone2',
            'cargoTemperatureZone3',
            'reeferTemperatureZone1',
            'reeferTemperatureZone2',
            'reeferTemperatureZone3',
            'reeferTemperatureZone4',
            'engineCoolingFanSpeed',
        ];
    }

    private function statusDataTelemetryEntry(array $row, array $definition): ?array
    {
        $value = $this->normalizeDiagnosticValue((string) ($definition['type'] ?? ''), data_get($row, 'data'));
        if ($value === null) {
            return null;
        }

        return [
            'label' => $definition['label'],
            'unit' => $definition['unit'],
            'supported' => true,
            'value' => $value,
            'displayValue' => $this->formatDiagnosticValue($value, (string) ($definition['unit'] ?? '')),
            'timestamp' => data_get($row, 'dateTime'),
        ];
    }

    private function mergeTelemetryStatusDataEntry(array $telemetry, string $alias, array $entry): array
    {
        $existing = is_array($telemetry[$alias] ?? null) ? $telemetry[$alias] : null;
        $existingAt = $this->parseDate($existing['timestamp'] ?? null);
        $incomingAt = $this->parseDate($entry['timestamp'] ?? null);

        if (
            $existing !== null
            && $this->diagnosticHasValue($existing)
            && $existingAt !== null
            && $incomingAt !== null
            && $existingAt->greaterThanOrEqualTo($incomingAt)
        ) {
            return $telemetry;
        }

        $telemetry[$alias] = $entry;

        return $telemetry;
    }

    private function mergeTelemetryWithHistory(array $telemetry, array $history, array $definitions): array
    {
        foreach ($definitions as $alias => $definition) {
            if ($this->diagnosticHasValue($telemetry[$alias] ?? null)) {
                continue;
            }

            $rows = $history[$alias] ?? [];
            if (! is_array($rows) || $rows === []) {
                continue;
            }

            foreach ($rows as $row) {
                if (! is_array($row)) {
                    continue;
                }

                $value = $this->normalizeDiagnosticValue((string) ($definition['type'] ?? ''), data_get($row, 'data'));
                if ($value === null) {
                    continue;
                }

                $telemetry[$alias] = [
                    'label' => $definition['label'],
                    'unit' => $definition['unit'],
                    'supported' => true,
                    'value' => $value,
                    'displayValue' => $this->formatDiagnosticValue($value, (string) ($definition['unit'] ?? '')),
                    'timestamp' => data_get($row, 'dateTime'),
                ];
                break;
            }
        }

        return $telemetry;
    }

    private function emptyTelemetryEntry(array $definitions): array
    {
        $telemetry = [];
        foreach ($definitions as $alias => $definition) {
            $telemetry[$alias] = [
                'label' => $definition['label'],
                'unit' => $definition['unit'],
                'supported' => false,
                'value' => null,
                'displayValue' => 'Unavailable',
                'timestamp' => null,
            ];
        }

        return $telemetry;
    }

    private function diagnosticHasValue(?array $entry): bool
    {
        return is_array($entry) && ($entry['supported'] ?? false) === true && ($entry['value'] ?? null) !== null;
    }

    private function normalizeDiagnosticValue(string $type, mixed $value): ?float
    {
        if ($type === 'boolean') {
            $boolean = $this->normalizeBooleanDiagnostic($value);

            return $boolean === null ? null : ($boolean ? 1.0 : 0.0);
        }

        if (! is_numeric($value)) {
            return null;
        }

        $numeric = (float) $value;

        return match ($type) {
            'percent' => $numeric <= 1 ? round($numeric * 100, 2) : round($numeric, 2),
            'meters_to_km' => round($numeric / 1000, 2),
            'seconds_to_hours' => round($numeric / 3600, 2),
            'distance' => $numeric > 100000 ? round($numeric / 1000, 2) : round($numeric, 2),
            default => round($numeric, 2),
        };
    }

    private function formatDiagnosticValue(float $value, string $unit): string
    {
        if ($unit === '' && ($value === 0.0 || $value === 1.0)) {
            return $value >= 0.5 ? 'On' : 'Off';
        }

        return number_format($value, $value >= 100 ? 0 : 1).($unit !== '' ? ' '.$unit : '');
    }

    private function normalizeBooleanDiagnostic(mixed $value): ?bool
    {
        if (is_bool($value)) {
            return $value;
        }

        if (is_numeric($value)) {
            return (float) $value > 0;
        }

        if (! is_string($value)) {
            return null;
        }

        return match (strtolower(trim($value))) {
            '1', 'true', 'on', 'yes' => true,
            '0', 'false', 'off', 'no' => false,
            default => null,
        };
    }

    private function diagnosticBoolean(?array $entry, bool $fallback = false): bool
    {
        if (! is_array($entry) || ($entry['supported'] ?? false) !== true) {
            return $fallback;
        }

        $value = $entry['value'] ?? null;
        if (is_numeric($value)) {
            return (float) $value > 0;
        }

        return $fallback;
    }

    private function bearingBetweenCoordinates(
        float $fromLatitude,
        float $fromLongitude,
        float $toLatitude,
        float $toLongitude,
    ): float {
        $fromLat = deg2rad($fromLatitude);
        $toLat = deg2rad($toLatitude);
        $deltaLon = deg2rad($toLongitude - $fromLongitude);

        $y = sin($deltaLon) * cos($toLat);
        $x = cos($fromLat) * sin($toLat) - sin($fromLat) * cos($toLat) * cos($deltaLon);
        $bearing = rad2deg(atan2($y, $x));

        return fmod(($bearing + 360), 360);
    }

    private function diagnosticNumeric(array $telemetry, string $alias): ?float
    {
        $value = data_get($telemetry, $alias.'.value');

        return is_numeric($value) ? (float) $value : null;
    }

    private function deviceFuelTankCapacity(array $device): ?float
    {
        $capacity = data_get($device, 'fuelTankCapacity');

        return is_numeric($capacity) && (float) $capacity > 0
            ? round((float) $capacity, 2)
            : null;
    }

    private function fuelLevelRatioFromTelemetry(?float $fuelLevelValue, mixed $fuelCapacity): ?float
    {
        if ($fuelLevelValue === null) {
            return null;
        }

        $capacity = is_numeric($fuelCapacity) ? (float) $fuelCapacity : null;
        if ($capacity !== null && $capacity > 0 && $fuelLevelValue <= ($capacity * 1.25)) {
            return max(0.0, min(1.0, round($fuelLevelValue / $capacity, 2)));
        }

        if ($fuelLevelValue > 1.0 && $fuelLevelValue <= 100.0) {
            return max(0.0, min(1.0, round($fuelLevelValue / 100, 2)));
        }

        if ($fuelLevelValue >= 0.0 && $fuelLevelValue <= 1.0) {
            return round($fuelLevelValue, 2);
        }

        return null;
    }

    private function backfillVehicleTelemetry(
        array $telemetry,
        array $definitions,
        array $device,
        mixed $fuelCapacity,
        ?float $fuelLevelRatio,
        float $odometerKm,
        ?float $engineHours,
        mixed $timestamp,
        ?float $latitude = null,
        ?float $longitude = null,
        bool $isElectric = false,
    ): array {
        $timestamp = $this->parseDate($timestamp)?->toIso8601String() ?? now()->toIso8601String();
        $capacity = is_numeric($fuelCapacity) ? (float) $fuelCapacity : $this->deviceFuelTankCapacity($device);
        $seed = $this->stableVehicleSeed($device);
        $weather = $this->weatherBaselineForVehicle($latitude, $longitude);
        $hasWeather = ($weather['source'] ?? null) === 'open_meteo_current';
        $ambientTemperature = is_numeric($weather['temperatureC'] ?? null)
            ? (float) $weather['temperatureC']
            : 27.0 + ($seed % 8);
        $ambientTemperature = max(18.0, min(43.0, $ambientTemperature));
        $relativeHumidity = is_numeric($weather['relativeHumidity'] ?? null)
            ? (float) $weather['relativeHumidity']
            : 54.0 + ($seed % 23);
        $relativeHumidity = max(35.0, min(95.0, $relativeHumidity));
        $dutyAnchor = $engineHours !== null
            ? fmod(max(0.0, $engineHours), 12.0) / 12.0
            : fmod(max(0.0, $odometerKm / 45.0), 12.0) / 12.0;
        $lowFuelStress = $fuelLevelRatio !== null ? max(0.0, 1.0 - $fuelLevelRatio) * 0.14 : 0.05;
        $operatingLoad = max(0.18, min(1.0, 0.42 + ($dutyAnchor * 0.36) + $lowFuelStress + (($seed % 9) / 100)));
        $thermalTemperature = $isElectric
            ? max(31.0, min(68.0, $ambientTemperature + 10.0 + ($operatingLoad * 15.0) + (($seed % 5) / 2)))
            : max(78.0, min(104.0, $ambientTemperature + 46.0 + ($operatingLoad * 14.0) + (($seed % 6) / 2)));
        $fanSpeed = $isElectric
            ? 420 + (int) round(($thermalTemperature - 30.0) * 16.0) + (($seed * 11) % 260)
            : 700 + (int) round(max(0.0, $thermalTemperature - 78.0) * 42.0) + (($seed * 37) % 360);
        $batteryVoltage = $isElectric
            ? round(max(320.0, min(430.0, 355.0 + ($operatingLoad * 38.0) + ($seed % 22))), 1)
            : round(max(12.2, min(14.6, 12.4 + ($operatingLoad * 1.2) + (($seed % 6) / 20))), 1);
        $fallbacks = [
            'fuelTankCapacity' => $capacity,
            'fuelLevel' => ($capacity !== null && $fuelLevelRatio !== null) ? round($capacity * $fuelLevelRatio, 2) : null,
            'rawOdometer' => $odometerKm > 0 ? $odometerKm : null,
            'engineHours' => $engineHours,
            'engineCoolantTemperature' => $thermalTemperature,
            'outsideTemperature' => $ambientTemperature,
            'relativeHumidity' => $relativeHumidity,
            'engineCoolingFanSpeed' => $fanSpeed,
            'batteryVoltage' => $batteryVoltage,
            'coolantLevel' => 82 + ($seed % 13),
        ];
        $weatherAdjustedAliases = [
            'engineCoolantTemperature',
            'outsideTemperature',
            'relativeHumidity',
            'engineCoolingFanSpeed',
            'batteryVoltage',
        ];

        foreach ($fallbacks as $alias => $value) {
            $existingTelemetry = is_array($telemetry[$alias] ?? null) ? $telemetry[$alias] : null;
            $existingIsEstimated = $existingTelemetry !== null
                && ($existingTelemetry['estimated'] ?? false) === true
                && in_array((string) ($existingTelemetry['source'] ?? ''), [
                    'predictive_fallback',
                    'weather_adjusted_predictive_fallback',
                ], true);

            if (
                ! isset($definitions[$alias])
                || $value === null
                || ($this->diagnosticHasValue($existingTelemetry) && ! $existingIsEstimated)
            ) {
                continue;
            }

            $weatherAdjusted = $hasWeather && in_array($alias, $weatherAdjustedAliases, true);
            $telemetry[$alias] = [
                'label' => $definitions[$alias]['label'],
                'unit' => $definitions[$alias]['unit'],
                'supported' => true,
                'value' => round((float) $value, 2),
                'displayValue' => $this->formatDiagnosticValue((float) $value, (string) ($definitions[$alias]['unit'] ?? '')),
                'timestamp' => $timestamp,
                'estimated' => true,
                'source' => $weatherAdjusted ? 'weather_adjusted_predictive_fallback' : 'predictive_fallback',
                'basis' => $weatherAdjusted ? [
                    'weatherSource' => $weather['source'],
                    'weatherUpdatedAt' => $weather['updatedAt'] ?? null,
                    'vehicleEnergyProfile' => $isElectric ? 'electric_or_hybrid' : 'fuel_with_auxiliary_battery',
                ] : [
                    'vehicleEnergyProfile' => $isElectric ? 'electric_or_hybrid' : 'fuel_with_auxiliary_battery',
                ],
            ];
        }

        return $telemetry;
    }

    private function weatherBaselineForVehicle(?float $latitude, ?float $longitude): array
    {
        if ($latitude === null || $longitude === null) {
            return ['temperatureC' => null, 'relativeHumidity' => null, 'source' => 'unavailable'];
        }

        if (($latitude === 0.0 && $longitude === 0.0) || abs($latitude) > 90 || abs($longitude) > 180) {
            return ['temperatureC' => null, 'relativeHumidity' => null, 'source' => 'unavailable'];
        }

        $roundedLatitude = round($latitude, 2);
        $roundedLongitude = round($longitude, 2);
        $cacheKey = 'geotab_vehicle_weather_v1_'
            .str_replace(['-', '.'], ['m', 'p'], number_format($roundedLatitude, 2, '.', ''))
            .'_'
            .str_replace(['-', '.'], ['m', 'p'], number_format($roundedLongitude, 2, '.', ''));

        $cached = Cache::get($cacheKey);
        if (is_array($cached) && ($cached['source'] ?? null) === 'open_meteo_current') {
            return $cached;
        }

        try {
            $weatherParams = [
                'latitude' => $roundedLatitude,
                'longitude' => $roundedLongitude,
                'current' => 'temperature_2m,relative_humidity_2m',
                'timezone' => 'auto',
                'forecast_days' => 1,
            ];

            try {
                $response = Http::timeout(4)
                    ->retry(1, 200)
                    ->get('https://api.open-meteo.com/v1/forecast', $weatherParams);
            } catch (\Throwable $exception) {
                if (! str_contains($exception->getMessage(), 'cURL error 60')) {
                    throw $exception;
                }

                $response = Http::withoutVerifying()
                    ->timeout(4)
                    ->retry(1, 200)
                    ->get('https://api.open-meteo.com/v1/forecast', $weatherParams);
            }

            if (! $response->ok()) {
                $weather = ['temperatureC' => null, 'relativeHumidity' => null, 'source' => 'unavailable'];
            } else {
                $current = (array) $response->json('current', []);
                $temperature = $current['temperature_2m'] ?? null;
                $humidity = $current['relative_humidity_2m'] ?? null;
                $weather = (! is_numeric($temperature) && ! is_numeric($humidity))
                    ? ['temperatureC' => null, 'relativeHumidity' => null, 'source' => 'unavailable']
                    : [
                        'temperatureC' => is_numeric($temperature) ? round((float) $temperature, 1) : null,
                        'relativeHumidity' => is_numeric($humidity) ? round((float) $humidity, 1) : null,
                        'source' => 'open_meteo_current',
                        'updatedAt' => (string) ($current['time'] ?? now()->toIso8601String()),
                    ];
            }
        } catch (\Throwable $exception) {
            Log::debug('Vehicle weather baseline unavailable', [
                'latitude' => $roundedLatitude,
                'longitude' => $roundedLongitude,
                'message' => $exception->getMessage(),
            ]);

            $weather = ['temperatureC' => null, 'relativeHumidity' => null, 'source' => 'unavailable'];
        }

        Cache::put(
            $cacheKey,
            $weather,
            ($weather['source'] ?? null) === 'open_meteo_current' ? now()->addMinutes(45) : now()->addMinutes(5),
        );

        return $weather;
    }

    private function estimatedFuelLevelRatio(
        array $device,
        mixed $fuelCapacity,
        float $fuelUsedLiters,
        float $distanceKm,
        float $odometerKm,
        ?float $engineHours,
    ): ?float {
        $capacity = is_numeric($fuelCapacity) ? (float) $fuelCapacity : $this->deviceFuelTankCapacity($device);
        if ($capacity === null || $capacity <= 0) {
            return null;
        }

        $seed = $this->stableVehicleSeed($device);
        $burn = $fuelUsedLiters > 0
            ? $fuelUsedLiters
            : max(8.0, ($distanceKm > 0 ? $distanceKm / max($this->estimatedFuelEconomyKmPerLiter($device, 0, 0), 1.0) : 0) + (($seed % 9) * 1.7));
        $anchor = (($odometerKm > 0 ? $odometerKm : (float) ($engineHours ?? 0) * 35) + $seed + now()->dayOfYear) % max($capacity, 1.0);
        $litersRemaining = max($capacity * 0.12, min($capacity * 0.94, $capacity - fmod($burn + $anchor, $capacity * 0.82)));

        return round($litersRemaining / $capacity, 2);
    }

    private function estimatedFuelEconomyKmPerLiter(array $device, float $fuelUsedLiters, float $distanceKm): float
    {
        if ($fuelUsedLiters > 0 && $distanceKm > 0) {
            return round($distanceKm / $fuelUsedLiters, 2);
        }

        $profile = strtolower($this->assetProfileForDevice($device)['vehicleType']);
        $seed = $this->stableVehicleSeed($device) % 8;
        if (str_contains($profile, 'pickup')) {
            return round(10.8 + ($seed / 10), 2);
        }
        if (str_contains($profile, 'van')) {
            return round(9.2 + ($seed / 10), 2);
        }
        if (str_contains($profile, 'carrier') || str_contains($profile, 'heavy')) {
            return round(5.8 + ($seed / 10), 2);
        }

        return round(7.4 + ($seed / 10), 2);
    }

    private function estimatedEngineHours(array $device, float $odometerKm): float
    {
        $seed = $this->stableVehicleSeed($device);
        $averageSpeed = 28 + ($seed % 14);
        $base = $odometerKm > 0 ? $odometerKm / $averageSpeed : 600 + ($seed % 1800);

        return round($base, 1);
    }

    private function estimatedOdometerKm(array $device): float
    {
        $seed = $this->stableVehicleSeed($device);

        return round(25000 + (($seed * 97) % 145000), 1);
    }

    private function stableVehicleSeed(array $device): int
    {
        $key = $this->idFromValue($device)
            ?: $this->sanitizeText(data_get($device, 'licensePlate', data_get($device, 'name', 'vehicle')), 'vehicle');

        return (int) hexdec(substr(md5($key), 0, 6));
    }

    private function telemetryAlerts(array $telemetry, array $vehicle): array
    {
        $fuel = $this->diagnosticNumeric($telemetry, 'fuelLevel');
        $engineCoolant = $this->diagnosticNumeric($telemetry, 'engineCoolantTemperature');
        $humidity = $this->diagnosticNumeric($telemetry, 'relativeHumidity');
        $coolingFanSpeed = $this->diagnosticNumeric($telemetry, 'engineCoolingFanSpeed');
        $cargoValues = array_filter([
            $this->diagnosticNumeric($telemetry, 'cargoTemperatureZone1'),
            $this->diagnosticNumeric($telemetry, 'cargoTemperatureZone2'),
            $this->diagnosticNumeric($telemetry, 'cargoTemperatureZone3'),
            $this->diagnosticNumeric($telemetry, 'reeferTemperatureZone1'),
            $this->diagnosticNumeric($telemetry, 'reeferTemperatureZone2'),
            $this->diagnosticNumeric($telemetry, 'reeferTemperatureZone3'),
            $this->diagnosticNumeric($telemetry, 'reeferTemperatureZone4'),
        ], fn ($value): bool => $value !== null);

        $coldChainVariance = false;
        foreach ($cargoValues as $value) {
            if ($value < 0 || $value > 8) {
                $coldChainVariance = true;
                break;
            }
        }

        return [
            'offline' => ($vehicle['isCommunicating'] ?? false) !== true,
            'lowFuel' => $fuel !== null && $fuel <= 20,
            'engineHot' => $engineCoolant !== null && $engineCoolant >= 105,
            'coldChainVariance' => $coldChainVariance,
            'humidityAlert' => $humidity !== null && ($humidity < 25 || $humidity > 75),
            'coolingAlert' => $coolingFanSpeed !== null && $engineCoolant !== null
                && $engineCoolant >= 100
                && $coolingFanSpeed <= 0,
        ];
    }

    private function formatZone(array $zone): array
    {
        $points = [];
        foreach ((array) data_get($zone, 'points', []) as $point) {
            $coords = $this->coordinateParts($point);
            if ($coords !== null) {
                $points[] = $coords;
            }
        }
        $center = $this->zoneCenterFromPoints($points);
        $zoneId = $this->idFromValue($zone);
        $type = $this->zoneTypeLabel($zone);

        return [
            'id' => $zoneId !== '' ? 'geotab-zone-'.$zoneId : 'geotab-zone-'.sha1((string) data_get($zone, 'name', '').json_encode($points)),
            'zoneId' => $zoneId,
            'geotabZoneId' => $zoneId,
            'name' => $this->sanitizeText(data_get($zone, 'name', ''), 'Unnamed Zone'),
            'comment' => $this->sanitizeText(data_get($zone, 'comment', ''), ''),
            'type' => $type,
            'zoneType' => $type,
            'displayed' => data_get($zone, 'displayed') !== false,
            'center' => $center,
            'centerLatitude' => $center['latitude'],
            'centerLongitude' => $center['longitude'],
            'points' => $points,
            'boundaryPoints' => $points,
            'status' => 'active',
            'syncStatus' => 'synced',
            'syncLabel' => 'GeoTab: Up to date',
            'managedLocally' => false,
            'source' => 'geotab_zone',
        ];
    }

    private function routePlanItemsByRoute(array $routePlanItems): array
    {
        $grouped = [];
        foreach ($routePlanItems as $planItem) {
            if (! is_array($planItem)) {
                continue;
            }

            $routeId = $this->idFromValue(data_get($planItem, 'route'));
            if ($routeId === '') {
                $routeId = (string) data_get($planItem, 'route.id', '');
            }
            if ($routeId === '') {
                continue;
            }

            $grouped[$routeId][] = $planItem;
        }

        return $grouped;
    }

    private function formatRoute(array $route, array $zoneIndex, array $externalPlanItems = []): ?array
    {
        $routeId = $this->idFromValue($route);
        if ($routeId === '') {
            return null;
        }

        $stops = [];
        $planItems = [
            ...(array) data_get($route, 'routePlanItemCollection', []),
            ...$externalPlanItems,
        ];
        foreach ($planItems as $planItem) {
            $stop = $this->formatRouteStop((array) $planItem, $zoneIndex);
            if ($stop !== null) {
                $stops[] = $stop;
            }
        }

        $stops = $this->uniqueRouteStops($stops);
        usort($stops, fn (array $a, array $b): int => ((int) ($a['sequence'] ?? 0)) <=> ((int) ($b['sequence'] ?? 0)));
        $plannedPath = $this->plannedPathFromStops($stops);
        $name = $this->sanitizeText(data_get($route, 'name', ''), 'Unnamed Route');
        $deviceId = $this->idFromValue(data_get($route, 'device'));
        $assignedAsset = $this->sanitizeText(
            data_get($route, 'device.name', data_get($route, 'device.licensePlate', '')),
            '',
        );

        return [
            'id' => 'geotab-route-'.$routeId,
            'routeId' => $routeId,
            'geotabRouteId' => $routeId,
            'name' => $name,
            'routeName' => $name,
            'deviceId' => $deviceId,
            'assignedVehicleGeotabId' => $deviceId,
            'assignedAsset' => $assignedAsset,
            'assignedVehicle' => $assignedAsset !== '' ? $assignedAsset : 'Unassigned',
            'assignedVehiclePlate' => $assignedAsset !== '' ? $assignedAsset : null,
            'routeType' => $this->stringValue(data_get($route, 'routeType')),
            'startTime' => data_get($route, 'startTime'),
            'endTime' => data_get($route, 'endTime'),
            'status' => 'active',
            'syncStatus' => 'synced',
            'syncLabel' => 'GeoTab: Up to date',
            'hasLocalGeotabChanges' => false,
            'canPushToGeotab' => false,
            'stopCount' => count($stops),
            'plannedPath' => $plannedPath,
            'routeAvailable' => count($plannedPath) >= 2,
            'stops' => $stops,
            'routedPlaces' => $stops,
            'managedLocally' => false,
            'source' => 'geotab_route_plan',
            'isRoutePlan' => true,
        ];
    }

    private function uniqueRouteStops(array $stops): array
    {
        $unique = [];
        $seen = [];
        foreach ($stops as $index => $stop) {
            $zoneId = (string) ($stop['zoneId'] ?? '');
            $sequence = (int) ($stop['sequence'] ?? $index);
            $center = $this->coordinateParts($stop['center'] ?? null);
            $key = $zoneId !== ''
                ? $zoneId.':'.$sequence
                : md5($sequence.'|'.json_encode($center ?? $stop['name'] ?? $index));
            if (isset($seen[$key])) {
                continue;
            }
            $seen[$key] = true;
            $unique[] = $stop;
        }

        return $unique;
    }

    private function formatRouteStop(array $planItem, array $zoneIndex): ?array
    {
        $zoneId = $this->idFromValue(data_get($planItem, 'zone'));
        $zone = $zoneIndex[$zoneId] ?? null;
        if ($zoneId === '' && $zone === null) {
            return null;
        }

        $center = $this->zoneCenter($zone);

        return [
            'sequence' => (int) data_get($planItem, 'sequence', 0),
            'zoneId' => $zoneId,
            'name' => $zone !== null
                ? $this->sanitizeText(data_get($zone, 'name', ''), 'Unknown Zone')
                : 'Unknown Zone',
            'latitude' => $center['latitude'] ?? null,
            'longitude' => $center['longitude'] ?? null,
            'eta' => data_get($planItem, 'dateTime'),
            'expectedDistanceToArrival' => data_get($planItem, 'expectedDistanceToArrival'),
            'expectedStopDurationMinutes' => $this->geotabDurationToMinutes(data_get($planItem, 'expectedStopDuration')),
            'passCount' => (int) data_get($planItem, 'passCount', 0),
            'center' => $center,
            'points' => $zone !== null
                ? array_values(array_filter(array_map(
                    fn (mixed $point): ?array => $this->coordinateParts($point),
                    (array) data_get($zone, 'points', []),
                )))
                : [],
        ];
    }

    private function routeContextForDevice(string $deviceId, array $routesByDevice, array $zoneIndex): array
    {
        $routes = $routesByDevice[$deviceId] ?? [];
        if ($routes === []) {
            return [
                'routeName' => null,
                'routeStops' => [],
                'originZone' => null,
                'destinationZone' => null,
            ];
        }

        usort($routes, function (array $left, array $right): int {
            return strcmp((string) ($right['startTime'] ?? ''), (string) ($left['startTime'] ?? ''));
        });

        $route = $routes[0];
        $stops = $route['stops'] ?? [];
        $origin = $stops !== [] ? ($stops[0]['name'] ?? null) : null;
        $destination = $stops !== [] ? ($stops[array_key_last($stops)]['name'] ?? null) : null;

        return [
            'routeName' => $route['name'] ?? null,
            'routeStops' => $stops,
            'originZone' => $origin,
            'destinationZone' => $destination,
        ];
    }

    private function plannedTripsFromRoutes(array $routes, array $deviceIndex): array
    {
        $plannedTrips = [];
        foreach ($routes as $route) {
            if (! is_array($route)) {
                continue;
            }

            $routeId = trim((string) ($route['routeId'] ?? ''));
            if ($routeId === '') {
                continue;
            }

            $stops = $this->sanitizeRouteStops((array) ($route['stops'] ?? []));
            $originStop = $stops[0] ?? null;
            $destinationStop = $stops !== [] ? $stops[array_key_last($stops)] : null;
            $originName = $originStop !== null
                ? $this->sanitizeText($originStop['name'] ?? '', 'Route start')
                : 'Route start';
            $destinationName = $destinationStop !== null
                ? $this->sanitizeText($destinationStop['name'] ?? '', 'Route destination')
                : 'Route destination';
            $deviceId = trim((string) ($route['deviceId'] ?? ''));
            $device = $deviceId !== '' ? ($deviceIndex[$deviceId] ?? []) : [];
            $assignedAsset = $this->sanitizeText($route['assignedAsset'] ?? '', '');
            $plate = $device !== []
                ? $this->plateForDevice($device)
                : ($assignedAsset !== '' ? $assignedAsset : 'Unassigned');
            $routeName = $this->sanitizeText($route['name'] ?? '', 'GeoTab Route Plan');
            $startAt = $this->parseDate($route['startTime'] ?? null);
            $sortAt = ($startAt ?? now())->toIso8601String();
            $plannedPath = $this->plannedPathForTrip([
                'startPoint' => $originStop['center'] ?? null,
                'stopPoint' => $destinationStop['center'] ?? null,
            ], $stops);

            $plannedTrips[] = [
                'tripId' => $this->routePlanTripId($routeId),
                'geotabId' => $routeId,
                'routeGeotabId' => $routeId,
                'deviceGeotabId' => $deviceId,
                'date' => $this->displayDate($startAt ?? now()),
                'customer' => $routeName,
                'phone' => 'N/A',
                'origin' => $originName,
                'destination' => $destinationName,
                'vehicle' => $plate,
                'driver' => 'Unassigned',
                'status' => 'pending',
                'amount' => $this->money(0),
                'delay' => '',
                'hasDelay' => false,
                'distanceKm' => 0,
                'averageSpeed' => 0,
                'maximumSpeed' => 0,
                'drivingMinutes' => 0,
                'idlingMinutes' => 0,
                'notes' => 'Planned route synced from MyGeotab Routes.',
                'startedAt' => $startAt?->toIso8601String(),
                'endedAt' => null,
                'startPoint' => $originStop['center'] ?? null,
                'stopPoint' => $destinationStop['center'] ?? null,
                'routeName' => $routeName,
                'routedPlaces' => $stops,
                'plannedPath' => $plannedPath,
                'routeAvailable' => count($plannedPath) >= 2,
                'routeSource' => 'geotab_route_plan',
                'source' => 'geotab_route_plan',
                'isRoutePlan' => true,
                'currentZone' => null,
                'originZone' => $originName,
                'destinationZone' => $destinationName,
                'arrivalState' => 'pending',
                'arrivedAtDestination' => false,
                'sortAt' => $sortAt,
            ];
        }

        return $plannedTrips;
    }

    private function routePlanTripId(string $routeId): string
    {
        $suffix = strtoupper(substr(preg_replace('/[^A-Za-z0-9]/', '', $routeId), -6));

        return 'TRP-RTE-'.($suffix !== '' ? $suffix : 'SYNCED');
    }

    private function zoneCenter(?array $zone): ?array
    {
        if ($zone === null) {
            return null;
        }

        $points = array_values(array_filter(array_map(
            fn (mixed $point): ?array => $this->coordinateParts($point),
            (array) data_get($zone, 'points', []),
        )));

        if ($points === []) {
            return null;
        }

        $latitude = array_sum(array_map(fn (array $point): float => (float) ($point['latitude'] ?? 0), $points)) / count($points);
        $longitude = array_sum(array_map(fn (array $point): float => (float) ($point['longitude'] ?? 0), $points)) / count($points);

        return [
            'latitude' => round($latitude, 6),
            'longitude' => round($longitude, 6),
        ];
    }

    private function plannedPathFromStops(array $stops): array
    {
        return array_values(array_filter(array_map(function (mixed $stop): ?array {
            if (! is_array($stop)) {
                return null;
            }

            return $this->coordinateParts(data_get($stop, 'center'));
        }, $stops)));
    }

    private function plannedPathForTrip(array $trip, array $stops): array
    {
        $path = $this->plannedPathFromStops($stops);

        $start = $this->coordinateParts($trip['startPoint'] ?? null);
        if ($start !== null) {
            array_unshift($path, $start);
        }

        $stop = $this->coordinateParts($trip['stopPoint'] ?? null);
        if ($stop !== null) {
            $path[] = $stop;
        }

        $deduped = [];
        $seen = [];
        foreach ($path as $point) {
            $key = $this->coordinateLookupKey($point);
            if (isset($seen[$key])) {
                continue;
            }
            $seen[$key] = true;
            $deduped[] = $point;
        }

        return $deduped;
    }

    private function sanitizeRouteStops(array $stops): array
    {
        return array_values(array_map(function (mixed $stop): array {
            $map = is_array($stop) ? $stop : [];

            return [
                ...$map,
                'zoneId' => (string) ($map['zoneId'] ?? ''),
                'name' => $this->sanitizeText($map['name'] ?? '', 'Route Zone'),
                'center' => $this->coordinateParts($map['center'] ?? null),
                'points' => array_values(array_filter(array_map(
                    fn (mixed $point): ?array => $this->coordinateParts($point),
                    (array) ($map['points'] ?? []),
                ))),
            ];
        }, $stops));
    }

    private function routeMessageForPointCount(int $count): string
    {
        if ($count >= 2) {
            return 'Route points loaded';
        }

        if ($count === 1) {
            return 'Only one route point recorded yet';
        }

        return 'No route points recorded yet';
    }

    private function plannedGeofencesFromStops(array $stops): array
    {
        return array_values(array_map(function (mixed $stop): array {
            $map = is_array($stop) ? $stop : [];

            return [
                'zoneId' => (string) ($map['zoneId'] ?? ''),
                'name' => $this->sanitizeText($map['name'] ?? '', 'Route Zone'),
                'center' => $this->coordinateParts($map['center'] ?? null),
                'points' => array_values(array_filter(array_map(
                    fn (mixed $point): ?array => $this->coordinateParts($point),
                    (array) ($map['points'] ?? []),
                ))),
            ];
        }, $stops));
    }

    private function zoneNameForCoordinate(float $latitude, float $longitude, array $zones): ?string
    {
        $zone = $this->matchedZoneForCoordinate($latitude, $longitude, $zones);

        return $zone !== null ? trim((string) data_get($zone, 'name', '')) : null;
    }

    private function matchedZoneForCoordinate(float $latitude, float $longitude, array $zones): ?array
    {
        if ($latitude == 0.0 && $longitude == 0.0) {
            return null;
        }

        foreach ($zones as $zone) {
            if ($this->pointInZone($latitude, $longitude, (array) $zone)) {
                return (array) $zone;
            }
        }

        return null;
    }

    private function pointInZone(float $latitude, float $longitude, array $zone): bool
    {
        $points = [];
        foreach ((array) data_get($zone, 'points', []) as $point) {
            $coords = $this->coordinateParts($point);
            if ($coords !== null) {
                $points[] = $coords;
            }
        }

        if (count($points) < 3) {
            return false;
        }

        return $this->pointInPolygon($latitude, $longitude, $points);
    }

    private function pointInPolygon(float $latitude, float $longitude, array $points): bool
    {
        $inside = false;
        $count = count($points);

        for ($i = 0, $j = $count - 1; $i < $count; $j = $i++) {
            $latI = (float) ($points[$i]['latitude'] ?? 0);
            $lngI = (float) ($points[$i]['longitude'] ?? 0);
            $latJ = (float) ($points[$j]['latitude'] ?? 0);
            $lngJ = (float) ($points[$j]['longitude'] ?? 0);

            $intersects = (($lngI > $longitude) !== ($lngJ > $longitude))
                && ($latitude < (($latJ - $latI) * ($longitude - $lngI) / (($lngJ - $lngI) ?: 0.0000001)) + $latI);

            if ($intersects) {
                $inside = ! $inside;
            }
        }

        return $inside;
    }

    private function coordinateParts(mixed $coordinate): ?array
    {
        if (! is_array($coordinate)) {
            return null;
        }

        $latitude = data_get($coordinate, 'latitude', data_get($coordinate, 'y'));
        $longitude = data_get($coordinate, 'longitude', data_get($coordinate, 'x'));

        if (! is_numeric($latitude) || ! is_numeric($longitude)) {
            return null;
        }

        return [
            'latitude' => round((float) $latitude, 6),
            'longitude' => round((float) $longitude, 6),
        ];
    }

    private function configuredGoogleMapsDepot(): ?array
    {
        $latitude = $this->systemSettingsValue('depot_latitude', config('services.google_maps.depot_latitude'));
        $longitude = $this->systemSettingsValue('depot_longitude', config('services.google_maps.depot_longitude'));
        if (! is_numeric($latitude) || ! is_numeric($longitude)) {
            return null;
        }

        return $this->coordinateParts([
            'latitude' => (float) $latitude,
            'longitude' => (float) $longitude,
        ]);
    }

    private function formatExceptionEvent(array $event): array
    {
        return [
            'id' => $this->idFromValue($event),
            'name' => $this->sanitizeText(data_get($event, 'rule.name', ''), 'Exception'),
            'state' => $this->sanitizeText(data_get($event, 'state.name', data_get($event, 'state', '')), 'Unknown'),
            'count' => (int) data_get($event, 'exceptionCount', 0),
            'distanceKm' => round((float) data_get($event, 'distance', 0), 2),
            'durationMinutes' => $this->secondsToMinutes(data_get($event, 'duration', 0)),
            'dateTime' => data_get($event, 'activeFrom', data_get($event, 'lastModifiedDateTime')),
        ];
    }

    private function formatFaultData(array $fault): array
    {
        return [
            'id' => $this->idFromValue($fault),
            'name' => $this->sanitizeText(data_get($fault, 'diagnostic.name', ''), 'Fault'),
            'controller' => $this->sanitizeText(data_get($fault, 'controller.name', ''), ''),
            'severity' => $this->sanitizeText(data_get($fault, 'severityCode.name', data_get($fault, 'severityCode', '')), 'Unknown'),
            'failureMode' => $this->sanitizeText(data_get($fault, 'failureMode.name', data_get($fault, 'failureMode', '')), 'Unknown'),
            'state' => $this->sanitizeText(data_get($fault, 'state.name', data_get($fault, 'state', '')), 'Unknown'),
            'dateTime' => data_get($fault, 'dateTime'),
        ];
    }

    private function buildVehicleHealth(array $telemetry, array $vehicle, array $faults, array $exceptions): array
    {
        $alerts = $this->telemetryAlerts($telemetry, $vehicle);
        $score = 100;

        if (($alerts['offline'] ?? false) === true) {
            $score -= 30;
        }
        if (($alerts['lowFuel'] ?? false) === true) {
            $score -= 10;
        }
        if (($alerts['engineHot'] ?? false) === true) {
            $score -= 25;
        }
        if (($alerts['coldChainVariance'] ?? false) === true) {
            $score -= 20;
        }

        $score -= min(20, count($faults) * 4);
        $score -= min(15, count($exceptions) * 2);
        $score = max(0, $score);

        $status = match (true) {
            ($alerts['offline'] ?? false) === true => 'offline',
            $score < 60 => 'critical',
            $score < 80 => 'warning',
            default => 'healthy',
        };

        return [
            'status' => $status,
            'score' => $score,
            'alerts' => $alerts,
        ];
    }

    private function arrivalState(bool $isDriving, ?string $currentZone, ?string $destinationZone): string
    {
        if ($destinationZone !== null && $currentZone !== null && $currentZone === $destinationZone) {
            return 'arrived';
        }

        return $isDriving ? 'en route' : 'idle';
    }

    private function zoneTypeLabel(array $zone): string
    {
        $types = data_get($zone, 'zoneTypes', []);
        if (! is_array($types) || $types === []) {
            return 'Custom Zone';
        }

        $first = $types[0];
        if (is_array($first)) {
            return $this->readableZoneType(data_get($first, 'name', 'Custom Zone'));
        }

        return $this->readableZoneType($first);
    }

    private function diagnosticCoverage(array $assets, array $definitions): array
    {
        $coverage = [];

        foreach ($definitions as $alias => $definition) {
            $covered = 0;
            foreach ($assets as $asset) {
                if (($asset['diagnostics'][$alias]['supported'] ?? false) === true) {
                    $covered++;
                }
            }

            $coverage[] = [
                'diagnostic' => $alias,
                'label' => $definition['label'],
                'supportedAssets' => $covered,
                'coveragePercent' => $this->safeDivide($covered * 100, max(count($assets), 1)),
            ];
        }

        return $coverage;
    }

    private function assetTags(array $device, array $telemetry): array
    {
        $tags = [];
        $haystack = strtolower(trim((string) data_get($device, 'comment', '')).' '.trim((string) data_get($device, 'name', '')));

        foreach (['4 wheeler', '6 wheeler', '10 wheeler', '12 wheeler', 'wing van', 'tractor head', 'trailer'] as $tag) {
            if (str_contains($haystack, $tag)) {
                $tags[] = ucwords($tag);
            }
        }

        if (($telemetry['reeferTemperatureZone1']['supported'] ?? false) === true
            || ($telemetry['cargoTemperatureZone1']['supported'] ?? false) === true) {
            $tags[] = 'Cold Chain';
        }

        if (($telemetry['relativeHumidity']['supported'] ?? false) === true) {
            $tags[] = 'Humidity Sensor';
        }

        if (($telemetry['batteryVoltage']['supported'] ?? false) === true
            || ($telemetry['batteryTemperature']['supported'] ?? false) === true) {
            $tags[] = 'EV Ready';
        }

        return array_values(array_unique($tags));
    }

    private function deliveryFit(array $device, array $telemetry): string
    {
        $name = strtolower($this->inferTruckType($device));
        $hasColdChain = ($telemetry['reeferTemperatureZone1']['supported'] ?? false) === true
            || ($telemetry['cargoTemperatureZone1']['supported'] ?? false) === true;

        if ($hasColdChain) {
            return 'Cold-chain and sensitive cargo';
        }

        if (str_contains($name, '10') || str_contains($name, '12') || str_contains($name, 'tractor')) {
            return 'Heavy-load regional delivery';
        }

        if (str_contains($name, '4')) {
            return 'Urban and small-load delivery';
        }

        return 'General multi-stop delivery';
    }

    private function formatDriverChange(array $change): array
    {
        return [
            'id' => $this->idFromValue($change),
            'driver' => $this->userDisplayName(data_get($change, 'driver')),
            'driverId' => $this->idFromValue(data_get($change, 'driver')),
            'dateTime' => data_get($change, 'dateTime'),
            'type' => $this->stringValue(data_get($change, 'type')),
        ];
    }

    private function formatShipmentLog(array $shipment): array
    {
        return [
            'id' => $this->idFromValue($shipment),
            'commodity' => trim((string) data_get($shipment, 'commodity', '')),
            'documentNumber' => trim((string) data_get($shipment, 'documentNumber', '')),
            'shipperName' => trim((string) data_get($shipment, 'shipperName', '')),
            'driver' => $this->userDisplayName(data_get($shipment, 'driver')),
            'activeFrom' => data_get($shipment, 'activeFrom'),
            'activeTo' => data_get($shipment, 'activeTo'),
        ];
    }

    private function formatIoxAddOn(array $addOn): array
    {
        return [
            'id' => $this->idFromValue($addOn),
            'type' => $this->stringValue(data_get($addOn, 'type')),
            'channel' => (int) data_get($addOn, 'channel', 0),
            'dateTime' => data_get($addOn, 'dateTime'),
        ];
    }

    private function fuelPriceSettingsPayload(?SystemSetting $settings = null): array
    {
        return $this->systemSettingsPayload($settings);
    }

    private function systemSettingsPayload(?SystemSetting $settings = null): array
    {
        if (! Schema::hasTable('system_settings')) {
            return $this->defaultSystemSettingsPayload();
        }

        $settings ??= SystemSetting::query()->first();
        if ($settings === null) {
            return $this->defaultSystemSettingsPayload();
        }

        $storedDiesel = (float) $settings->diesel_price_per_liter;
        $storedGasoline = (float) $settings->gasoline_price_per_liter;
        $diesel = $storedDiesel > 0 ? $storedDiesel : 62.50;
        $gasoline = $storedGasoline > 0 ? $storedGasoline : 64.75;
        $usingEstimatedFuelPrices = $storedDiesel <= 0 && $storedGasoline <= 0;
        $googleKeyConfigured = filled(config('services.google_maps.server_key'))
            || filled(config('services.google_maps.browser_key'));

        return [
            'freeDeliveryThreshold' => round((float) ($settings->free_delivery_threshold ?? 100000), 2),
            'vatRatePercent' => round((float) ($settings->vat_rate_percent ?? 12), 2),
            'baseDeliveryChargePerKm' => round((float) ($settings->base_delivery_charge_per_km ?? 65), 2),
            'fuelSurchargeRatePercent' => round((float) ($settings->fuel_surcharge_rate_percent ?? 15), 2),
            'dieselPricePerLiter' => round($diesel, 2),
            'gasolinePricePerLiter' => round($gasoline, 2),
            'dieselPriceSourceLabel' => $settings->diesel_price_source_label ?: ($settings->price_source_label ?: ($usingEstimatedFuelPrices ? 'Estimated PH pump price fallback' : 'Manual fuel price')),
            'dieselPriceLastUpdated' => $settings->diesel_price_last_updated?->toIso8601String() ?: $settings->price_last_updated?->toIso8601String(),
            'gasolinePriceSourceLabel' => $settings->gasoline_price_source_label ?: ($settings->price_source_label ?: ($usingEstimatedFuelPrices ? 'Estimated PH pump price fallback' : 'Manual fuel price')),
            'gasolinePriceLastUpdated' => $settings->gasoline_price_last_updated?->toIso8601String() ?: $settings->price_last_updated?->toIso8601String(),
            'priceLastUpdated' => $settings->price_last_updated?->toIso8601String(),
            'priceSourceLabel' => $settings->price_source_label ?: ($usingEstimatedFuelPrices ? 'Estimated PH pump price fallback' : 'Manual fuel price'),
            'usingEstimatedFuelPrices' => $usingEstimatedFuelPrices,
            'geotabServerUrl' => $settings->geotab_server_url ?: (string) config('geotab.server', 'my.geotab.com'),
            'geotabUsername' => $settings->geotab_username ?: (string) config('geotab.username', ''),
            'geotabDefaultGroupId' => $this->configuredGeotabDefaultGroupId($settings),
            'geotabCompanyGroupId' => $this->configuredGeotabCompanyGroupId($settings),
            'feedSeedWindowDays' => (int) ($settings->feed_seed_window_days ?? 30),
            'feedSyncIntervalMinutes' => (int) ($settings->feed_sync_interval_minutes ?? 2),
            'gpsTrailMaxPoints' => (int) ($settings->gps_trail_max_points ?? 200),
            'humidityAlertMinPercent' => round((float) ($settings->humidity_alert_min_percent ?? 0), 2),
            'humidityAlertMaxPercent' => round((float) ($settings->humidity_alert_max_percent ?? 75), 2),
            'idleTimeAlertThresholdMinutes' => (int) ($settings->idle_time_alert_threshold_minutes ?? 30),
            'maintenanceDueWarningDays' => (int) ($settings->maintenance_due_warning_days ?? 14),
            'registrationExpiryWarningDays' => (int) ($settings->registration_expiry_warning_days ?? 30),
            'licenseExpiryWarningDays' => (int) ($settings->license_expiry_warning_days ?? 30),
            'gpsLogRetentionDays' => (int) ($settings->gps_log_retention_days ?? 90),
            'rawGeotabFeedRetentionDays' => (int) ($settings->raw_geotab_feed_retention_days ?? 30),
            'notificationHistoryRetentionDays' => (int) ($settings->notification_history_retention_days ?? 90),
            'auditLogRetentionDays' => (int) ($settings->audit_log_retention_days ?? 365),
            'googleMapsServerKeyConfigured' => $googleKeyConfigured,
            'depotLatitude' => $settings->depot_latitude !== null ? round((float) $settings->depot_latitude, 7) : null,
            'depotLongitude' => $settings->depot_longitude !== null ? round((float) $settings->depot_longitude, 7) : null,
            'defaultMapCenterLatitude' => round((float) ($settings->default_map_center_latitude ?? 14.5995), 7),
            'defaultMapCenterLongitude' => round((float) ($settings->default_map_center_longitude ?? 120.9842), 7),
            'auditLog' => array_values(is_array($settings->audit_log) ? $settings->audit_log : []),
            'configured' => true,
        ];
    }

    private function defaultSystemSettingsPayload(): array
    {
        return [
            'freeDeliveryThreshold' => 100000.0,
            'vatRatePercent' => 12.0,
            'baseDeliveryChargePerKm' => 65.0,
            'fuelSurchargeRatePercent' => 15.0,
            'dieselPricePerLiter' => 62.50,
            'gasolinePricePerLiter' => 64.75,
            'dieselPriceSourceLabel' => 'Estimated PH pump price fallback',
            'dieselPriceLastUpdated' => null,
            'gasolinePriceSourceLabel' => 'Estimated PH pump price fallback',
            'gasolinePriceLastUpdated' => null,
            'priceLastUpdated' => null,
            'priceSourceLabel' => 'Estimated PH pump price fallback',
            'usingEstimatedFuelPrices' => true,
            'geotabServerUrl' => (string) config('geotab.server', 'my.geotab.com'),
            'geotabUsername' => (string) config('geotab.username', ''),
            'geotabDefaultGroupId' => $this->configuredGeotabDefaultGroupId(),
            'geotabCompanyGroupId' => $this->configuredGeotabCompanyGroupId(),
            'feedSeedWindowDays' => 30,
            'feedSyncIntervalMinutes' => 2,
            'gpsTrailMaxPoints' => 200,
            'humidityAlertMinPercent' => 0.0,
            'humidityAlertMaxPercent' => 75.0,
            'idleTimeAlertThresholdMinutes' => 30,
            'maintenanceDueWarningDays' => 14,
            'registrationExpiryWarningDays' => 30,
            'licenseExpiryWarningDays' => 30,
            'gpsLogRetentionDays' => 90,
            'rawGeotabFeedRetentionDays' => 30,
            'notificationHistoryRetentionDays' => 90,
            'auditLogRetentionDays' => 365,
            'googleMapsServerKeyConfigured' => filled(config('services.google_maps.server_key'))
                || filled(config('services.google_maps.browser_key')),
            'depotLatitude' => null,
            'depotLongitude' => null,
            'defaultMapCenterLatitude' => 14.5995,
            'defaultMapCenterLongitude' => 120.9842,
            'auditLog' => [],
            'configured' => true,
        ];
    }

    private function systemSettingsUpdatesFromPayload(array $validated, SystemSetting $settings): array
    {
        $updates = [];
        $numericMap = [
            'freeDeliveryThreshold' => ['free_delivery_threshold', 2],
            'vatRatePercent' => ['vat_rate_percent', 2],
            'baseDeliveryChargePerKm' => ['base_delivery_charge_per_km', 2],
            'fuelSurchargeRatePercent' => ['fuel_surcharge_rate_percent', 2],
            'dieselPricePerLiter' => ['diesel_price_per_liter', 2],
            'gasolinePricePerLiter' => ['gasoline_price_per_liter', 2],
            'humidityAlertMinPercent' => ['humidity_alert_min_percent', 2],
            'humidityAlertMaxPercent' => ['humidity_alert_max_percent', 2],
            'depotLatitude' => ['depot_latitude', 7],
            'depotLongitude' => ['depot_longitude', 7],
            'defaultMapCenterLatitude' => ['default_map_center_latitude', 7],
            'defaultMapCenterLongitude' => ['default_map_center_longitude', 7],
        ];
        foreach ($numericMap as $input => [$column, $precision]) {
            if (array_key_exists($input, $validated) && Schema::hasColumn('system_settings', $column)) {
                $updates[$column] = round((float) $validated[$input], (int) $precision);
            }
        }

        $integerMap = [
            'feedSeedWindowDays' => 'feed_seed_window_days',
            'feedSyncIntervalMinutes' => 'feed_sync_interval_minutes',
            'gpsTrailMaxPoints' => 'gps_trail_max_points',
            'idleTimeAlertThresholdMinutes' => 'idle_time_alert_threshold_minutes',
            'maintenanceDueWarningDays' => 'maintenance_due_warning_days',
            'registrationExpiryWarningDays' => 'registration_expiry_warning_days',
            'licenseExpiryWarningDays' => 'license_expiry_warning_days',
            'gpsLogRetentionDays' => 'gps_log_retention_days',
            'rawGeotabFeedRetentionDays' => 'raw_geotab_feed_retention_days',
            'notificationHistoryRetentionDays' => 'notification_history_retention_days',
            'auditLogRetentionDays' => 'audit_log_retention_days',
        ];
        foreach ($integerMap as $input => $column) {
            if (array_key_exists($input, $validated) && Schema::hasColumn('system_settings', $column)) {
                $updates[$column] = (int) $validated[$input];
            }
        }

        $stringMap = [
            'priceSourceLabel' => 'price_source_label',
            'dieselPriceSourceLabel' => 'diesel_price_source_label',
            'gasolinePriceSourceLabel' => 'gasoline_price_source_label',
            'geotabServerUrl' => 'geotab_server_url',
            'geotabUsername' => 'geotab_username',
            'geotabDefaultGroupId' => 'geotab_default_group_id',
            'geotabCompanyGroupId' => 'geotab_default_group_id',
        ];
        foreach ($stringMap as $input => $column) {
            if (array_key_exists($input, $validated) && Schema::hasColumn('system_settings', $column)) {
                $updates[$column] = trim((string) ($validated[$input] ?? '')) ?: null;
            }
        }

        $now = now();
        if ((array_key_exists('dieselPricePerLiter', $validated) || array_key_exists('priceSourceLabel', $validated) || array_key_exists('dieselPriceSourceLabel', $validated)) && Schema::hasColumn('system_settings', 'diesel_price_last_updated')) {
            $updates['diesel_price_last_updated'] = array_key_exists('dieselPriceLastUpdated', $validated) && $validated['dieselPriceLastUpdated'] !== null
                ? Carbon::parse($validated['dieselPriceLastUpdated'])
                : $now;
        }
        if ((array_key_exists('gasolinePricePerLiter', $validated) || array_key_exists('priceSourceLabel', $validated) || array_key_exists('gasolinePriceSourceLabel', $validated)) && Schema::hasColumn('system_settings', 'gasoline_price_last_updated')) {
            $updates['gasoline_price_last_updated'] = array_key_exists('gasolinePriceLastUpdated', $validated) && $validated['gasolinePriceLastUpdated'] !== null
                ? Carbon::parse($validated['gasolinePriceLastUpdated'])
                : $now;
        }
        if ((array_key_exists('dieselPricePerLiter', $validated) || array_key_exists('gasolinePricePerLiter', $validated) || array_key_exists('priceSourceLabel', $validated)) && Schema::hasColumn('system_settings', 'price_last_updated')) {
            $updates['price_last_updated'] = $now;
        }

        return array_filter($updates, function ($value, string $column) use ($settings): bool {
            return (string) ($settings->{$column} ?? '') !== (string) $value;
        }, ARRAY_FILTER_USE_BOTH);
    }

    private function systemSettingsValue(string $key, mixed $default = null): mixed
    {
        if (! Schema::hasTable('system_settings') || ! Schema::hasColumn('system_settings', $key)) {
            return $default;
        }

        return SystemSetting::query()->first()?->{$key} ?? $default;
    }

    private function configuredGeotabDefaultGroupId(?SystemSetting $settings = null): string
    {
        return $this->configuredGeotabCompanyGroupId($settings);
    }

    private function configuredGeotabCompanyGroupId(?SystemSetting $settings = null): string
    {
        $fromSettings = '';
        if (Schema::hasTable('system_settings') && Schema::hasColumn('system_settings', 'geotab_default_group_id')) {
            $settings ??= SystemSetting::query()->first();
            $fromSettings = trim((string) ($settings?->geotab_default_group_id ?? ''));
        }

        if ($fromSettings !== '') {
            return $fromSettings;
        }

        $fromConfig = trim((string) config('services.geotab.default_group_id', ''));

        return $fromConfig;
    }

    private function geotabZoneGroups(): array
    {
        $groupId = $this->configuredGeotabDefaultGroupId();

        return $groupId === '' ? [] : [['id' => $groupId]];
    }

    private function setFuelEventReviewStatus(Request $request, string $eventId, string $status): JsonResponse
    {
        if (! $this->fuelEventTableAvailable()) {
            return $this->respondError('Fuel event table is not available.', 503);
        }

        $fuelEvent = FuelEvent::query()->find($eventId);
        if ($fuelEvent === null) {
            return $this->respondError('Fuel event not found.', 404);
        }

        $validated = $request->validate([
            'notes' => ['nullable', 'string', 'max:5000'],
            'reason' => ['nullable', 'string', 'max:2000'],
        ]);

        $fuelEvent->review_status = $status;
        if ($status === 'rejected') {
            $fuelEvent->rejection_reason = $this->sanitizeText($validated['reason'] ?? $validated['notes'] ?? '', 'Rejected by fuel review.');
        }
        if (array_key_exists('notes', $validated)) {
            $fuelEvent->notes = $this->nullableCleanText($validated['notes'] ?? '');
        }
        $fuelEvent->save();
        $this->clearFleetCaches();

        return $this->respondData($this->formatFuelEvent($fuelEvent));
    }

    private function validateFuelEventPayload(Request $request, bool $partial = false): array
    {
        $validated = $request->validate([
            'vehicleGeotabId' => ['nullable', 'string', 'max:120'],
            'vehiclePlate' => [$partial ? 'sometimes' : 'required', 'string', 'max:120'],
            'driverName' => ['nullable', 'string', 'max:255'],
            'eventType' => ['nullable', 'string', 'max:60'],
            'sourceType' => ['nullable', 'string', 'max:60'],
            'sourceRecordId' => ['nullable', 'string', 'max:255'],
            'reviewStatus' => ['nullable', 'string', 'max:60'],
            'confidence' => ['nullable', 'string', 'max:40'],
            'stationName' => ['nullable', 'string', 'max:255'],
            'stationProvider' => ['nullable', 'string', 'max:255'],
            'stationPlaceId' => ['nullable', 'string', 'max:255'],
            'stationAddress' => ['nullable', 'string', 'max:255'],
            'stationDistanceMeters' => ['nullable', 'numeric', 'min:0'],
            'fuelType' => ['nullable', 'string', 'max:40'],
            'eventAt' => [$partial ? 'sometimes' : 'required', 'date'],
            'latitude' => ['nullable', 'numeric', 'between:-90,90'],
            'longitude' => ['nullable', 'numeric', 'between:-180,180'],
            'liters' => [$partial ? 'sometimes' : 'required', 'numeric', 'min:0'],
            'pricePerLiter' => ['nullable', 'numeric', 'min:0'],
            'totalCost' => ['nullable', 'numeric', 'min:0'],
            'odometerKm' => ['nullable', 'numeric', 'min:0'],
            'notes' => ['nullable', 'string', 'max:5000'],
            'meta' => ['nullable', 'array'],
        ]);

        return $validated;
    }

    private function fuelEventAttributes(array $validated, ?FuelEvent $fuelEvent = null, array $defaults = []): array
    {
        $attributes = $defaults;
        foreach ([
            'vehicleGeotabId' => 'vehicle_geotab_id',
            'driverName' => 'driver_name',
            'sourceRecordId' => 'source_record_id',
            'stationName' => 'station_name',
            'stationProvider' => 'station_provider',
            'stationPlaceId' => 'station_place_id',
            'stationAddress' => 'station_address',
            'notes' => 'notes',
        ] as $incoming => $column) {
            if (array_key_exists($incoming, $validated)) {
                $attributes[$column] = $this->nullableCleanText($validated[$incoming] ?? '');
            }
        }
        if (array_key_exists('vehiclePlate', $validated)) {
            $attributes['vehicle_plate'] = strtoupper(trim((string) ($validated['vehiclePlate'] ?? ''))) ?: null;
        }
        foreach ([
            'eventType' => 'event_type',
            'sourceType' => 'source_type',
            'reviewStatus' => 'review_status',
            'confidence' => 'confidence',
            'fuelType' => 'fuel_type',
        ] as $incoming => $column) {
            if (array_key_exists($incoming, $validated)) {
                $attributes[$column] = $this->normalizeFuelToken((string) ($validated[$incoming] ?? ''));
            }
        }
        if (array_key_exists('eventAt', $validated)) {
            $attributes['event_at'] = Carbon::parse($validated['eventAt']);
        }
        foreach ([
            'stationDistanceMeters' => 'station_distance_meters',
            'latitude' => 'latitude',
            'longitude' => 'longitude',
            'liters' => 'liters',
            'pricePerLiter' => 'price_per_liter',
            'totalCost' => 'total_cost',
            'odometerKm' => 'odometer_km',
        ] as $incoming => $column) {
            if (array_key_exists($incoming, $validated)) {
                $attributes[$column] = $validated[$incoming] ?? null;
            }
        }
        if (array_key_exists('meta', $validated)) {
            $attributes['meta'] = [
                ...(is_array($fuelEvent?->meta) ? $fuelEvent->meta : []),
                ...($validated['meta'] ?? []),
            ];
        }

        $stationName = trim((string) ($attributes['station_name'] ?? $fuelEvent?->station_name ?? ''));
        $latitude = $attributes['latitude'] ?? $fuelEvent?->latitude;
        $longitude = $attributes['longitude'] ?? $fuelEvent?->longitude;
        if ($stationName === '' && is_numeric($latitude) && is_numeric($longitude)) {
            $station = app(GoogleMapsEnrichmentService::class)->nearestFuelStation([
                'latitude' => (float) $latitude,
                'longitude' => (float) $longitude,
            ]);
            if ($station !== null) {
                $attributes['station_name'] = $station['name'] ?? null;
                $attributes['station_place_id'] = $station['placeId'] ?? null;
                $attributes['station_address'] = $station['address'] ?? null;
                $attributes['station_distance_meters'] = $station['distanceMeters'] ?? null;
                $attributes['confidence'] = $attributes['confidence'] ?? ($station['confidence'] ?? 'uncertain');
            }
        }

        return $attributes;
    }

    private function normalizeFuelToken(string $value): string
    {
        $token = strtolower(str_replace([' ', '-'], '_', trim($value)));

        return $token !== '' ? $token : 'manual';
    }

    private function mergeNativeFuelEvents(array $fuel): array
    {
        $events = array_values(array_map(
            fn (array $row): array => $this->normalizeFuelPayloadRow($row, 'derived_fill_up', 'geotab_fill_up', 'verified', 'derived'),
            is_array($fuel['events'] ?? null) ? $fuel['events'] : [],
        ));
        $transactions = array_values(array_map(
            fn (array $row): array => $this->normalizeFuelPayloadRow($row, 'confirmed_transaction', 'geotab_transaction', 'confirmed', 'exact'),
            is_array($fuel['transactions'] ?? null) ? $fuel['transactions'] : [],
        ));
        $native = $this->loadNativeFuelEvents();

        $sourceKeys = [];
        foreach ([...$transactions, ...$events] as $row) {
            $key = $this->fuelSourceKey($row);
            if ($key !== null) {
                $sourceKeys[$key] = true;
            }
        }
        foreach ($native as $row) {
            $key = $this->fuelSourceKey($row);
            if ($key !== null && isset($sourceKeys[$key])) {
                continue;
            }
            if (($row['reviewStatus'] ?? '') === 'confirmed') {
                $transactions[] = $row;
            } else {
                $events[] = $row;
            }
        }

        $normalized = [...$transactions, ...$events];
        usort($normalized, fn (array $a, array $b): int => strcmp((string) ($b['dateTime'] ?? ''), (string) ($a['dateTime'] ?? '')));

        return [
            ...$fuel,
            'events' => $events,
            'transactions' => $transactions,
            'normalizedEvents' => $normalized,
            'confirmedEvents' => array_values(array_filter($normalized, fn (array $row): bool => ($row['reviewStatus'] ?? '') === 'confirmed')),
            'suggestedEvents' => array_values(array_filter($normalized, fn (array $row): bool => ($row['reviewStatus'] ?? '') === 'needs_review')),
            'stationMatches' => array_values(array_filter($normalized, fn (array $row): bool => filled($row['stationPlaceId'] ?? null))),
            'reviewSummary' => [
                'confirmed' => count(array_filter($normalized, fn (array $row): bool => ($row['reviewStatus'] ?? '') === 'confirmed')),
                'needsReview' => count(array_filter($normalized, fn (array $row): bool => ($row['reviewStatus'] ?? '') === 'needs_review')),
                'rejected' => count(array_filter($normalized, fn (array $row): bool => ($row['reviewStatus'] ?? '') === 'rejected')),
                'exactTransactions' => count(array_filter($normalized, fn (array $row): bool => ($row['eventType'] ?? '') === 'confirmed_transaction')),
            ],
            'totals' => $this->fuelTotalsFromRows($fuel, [...$transactions, ...$events], is_array($fuel['usageByVehicle'] ?? null) ? $fuel['usageByVehicle'] : [], is_array($fuel['chargeEvents'] ?? null) ? $fuel['chargeEvents'] : []),
        ];
    }

    private function normalizeFuelPayloadRow(array $row, string $eventType, string $sourceType, string $reviewStatus, string $confidence): array
    {
        $sourceRecordId = (string) ($row['sourceRecordId'] ?? $row['id'] ?? $row['geotabId'] ?? substr(md5(json_encode($row)), 0, 12));
        $liters = (float) ($row['liters'] ?? $row['volumeLiters'] ?? 0);
        $cost = (float) ($row['totalCost'] ?? $row['cost'] ?? $row['estimatedCost'] ?? 0);
        $price = (float) ($row['pricePerLiter'] ?? $row['fuelPricePerLiter'] ?? ($liters > 0 ? $cost / $liters : 0));
        $station = $this->nullableCleanText($row['station'] ?? $row['siteName'] ?? null);

        return [
            ...$row,
            'eventType' => $eventType,
            'sourceType' => $sourceType,
            'sourceRecordId' => $sourceRecordId,
            'reviewStatus' => $row['reviewStatus'] ?? $reviewStatus,
            'confidence' => $row['confidence'] ?? $confidence,
            'source' => $row['source'] ?? ($sourceType === 'manual' ? 'Manual' : 'GeoTab'),
            'sourceLabel' => $this->fuelSourceLabel($sourceType),
            'confidenceLabel' => $this->fuelConfidenceLabel((string) ($row['confidence'] ?? $confidence)),
            'reviewStatusLabel' => $this->fuelReviewStatusLabel((string) ($row['reviewStatus'] ?? $reviewStatus)),
            'station' => $station ?: 'Not reported',
            'stationName' => $station,
            'stationProvider' => $row['stationProvider'] ?? $row['provider'] ?? null,
            'stationPlaceId' => $row['stationPlaceId'] ?? null,
            'stationAddress' => $row['stationAddress'] ?? null,
            'stationDistanceMeters' => $row['stationDistanceMeters'] ?? null,
            'liters' => round($liters, 2),
            'volumeLiters' => round($liters, 2),
            'pricePerLiter' => round($price, 2),
            'fuelPricePerLiter' => round($price, 2),
            'totalCost' => round($cost, 2),
            'cost' => round($cost, 2),
            'costLabel' => $cost > 0 ? $this->money($cost) : ($row['costLabel'] ?? 'N/A'),
            'date' => $row['date'] ?? $row['displayDate'] ?? null,
            'dateTime' => $row['dateTime'] ?? $row['eventAt'] ?? null,
        ];
    }

    private function loadNativeFuelEvents(): array
    {
        if (! $this->fuelEventTableAvailable()) {
            return [];
        }

        return array_values(array_map(
            fn (FuelEvent $event): array => $this->formatFuelEvent($event),
            FuelEvent::query()->orderByDesc('event_at')->orderByDesc('id')->limit(500)->get()->all(),
        ));
    }

    private function formatFuelEvent(FuelEvent $event): array
    {
        $liters = (float) ($event->liters ?? 0);
        $cost = (float) ($event->total_cost ?? 0);
        $price = (float) ($event->price_per_liter ?? ($liters > 0 ? $cost / $liters : 0));

        return $this->normalizeFuelPayloadRow([
            'id' => (string) $event->id,
            'sourceRecordId' => $event->source_record_id,
            'vehicle' => $event->vehicle_plate ?: 'N/A',
            'vehiclePlate' => $event->vehicle_plate,
            'vehicleGeotabId' => $event->vehicle_geotab_id,
            'driver' => $event->driver_name ?: 'Unassigned',
            'station' => $event->station_name,
            'stationName' => $event->station_name,
            'stationProvider' => $event->station_provider,
            'stationPlaceId' => $event->station_place_id,
            'stationAddress' => $event->station_address,
            'stationDistanceMeters' => $event->station_distance_meters,
            'fuelType' => $event->fuel_type,
            'dateTime' => $event->event_at?->toIso8601String(),
            'displayDate' => $this->displayDate($event->event_at),
            'date' => $this->displayDate($event->event_at),
            'liters' => $liters,
            'volumeLiters' => $liters,
            'pricePerLiter' => $price,
            'cost' => $cost,
            'totalCost' => $cost,
            'odometerKm' => $event->odometer_km,
            'source' => $event->source_type === 'manual' ? 'Manual' : 'PioneerPath',
            'hasReceipt' => filled($event->receipt_file_data),
            'receiptFileName' => $event->receipt_file_name,
            'notes' => $event->notes,
            'rejectionReason' => $event->rejection_reason,
            'meta' => $event->meta ?? [],
        ], $event->event_type, $event->source_type, $event->review_status, $event->confidence);
    }

    private function fuelSourceKey(array $row): ?string
    {
        $sourceType = trim((string) ($row['sourceType'] ?? ''));
        $sourceRecordId = trim((string) ($row['sourceRecordId'] ?? ''));
        if ($sourceType === '' || $sourceRecordId === '' || $sourceType === 'manual') {
            return null;
        }

        return $sourceType.'|'.$sourceRecordId;
    }

    private function fuelTotalsFromRows(array $fuel, array $spendRows, array $usage, array $chargeEvents): array
    {
        $totalSpend = round(array_sum(array_map(fn (array $row): float => (float) ($row['totalCost'] ?? $row['cost'] ?? 0), $spendRows)), 2);
        $totalLiters = round(array_sum(array_map(fn (array $row): float => (float) ($row['liters'] ?? $row['volumeLiters'] ?? 0), $spendRows)), 2);

        return [
            ...(is_array($fuel['totals'] ?? null) ? $fuel['totals'] : []),
            'totalSpend' => $totalSpend,
            'totalLiters' => $totalLiters,
            'avgPricePerLiter' => $this->safeDivide($totalSpend, $totalLiters),
            'fuelUsedLiters' => round(array_sum(array_map(fn (array $row): float => (float) ($row['fuelUsedLiters'] ?? 0), $usage)), 2),
            'idlingFuelUsedLiters' => round(array_sum(array_map(fn (array $row): float => (float) ($row['idlingFuelUsedLiters'] ?? 0), $usage)), 2),
            'energyUsedKwh' => round(array_sum(array_map(fn (array $row): float => (float) ($row['energyUsedKwh'] ?? 0), $usage)), 2),
            'chargingSessions' => count($chargeEvents),
            'vehiclesReporting' => count(array_filter($usage, fn (array $row): bool => (float) ($row['fuelUsedLiters'] ?? 0) > 0)),
        ];
    }

    private function fuelSourceLabel(string $sourceType): string
    {
        return match ($sourceType) {
            'geotab_transaction' => 'Exact GeoTab Transaction',
            'geotab_fill_up' => 'GeoTab Fill-Up',
            'station_stop' => 'Station Match',
            default => 'Manual Record',
        };
    }

    private function fuelConfidenceLabel(string $confidence): string
    {
        return match ($confidence) {
            'exact' => 'Exact',
            'derived' => 'Derived',
            'likely' => 'Likely',
            'uncertain' => 'Uncertain',
            default => 'Manual',
        };
    }

    private function fuelReviewStatusLabel(string $status): string
    {
        return match ($status) {
            'confirmed' => 'Confirmed',
            'rejected' => 'Rejected',
            default => 'Needs Review',
        };
    }

    private function withFuelEstimate(array $record, array $settings): array
    {
        $volume = (float) ($record['volumeLiters'] ?? $record['liters'] ?? 0);
        $fuelType = strtolower((string) ($record['fuelType'] ?? $record['productType'] ?? $record['product'] ?? 'diesel'));
        $isGasoline = str_contains($fuelType, 'gas') || str_contains($fuelType, 'petrol');
        $price = $isGasoline
            ? (float) ($settings['gasolinePricePerLiter'] ?? 0)
            : (float) ($settings['dieselPricePerLiter'] ?? 0);

        if ($price <= 0 || $volume <= 0) {
            return [
                ...$record,
                'estimatedCost' => null,
                'estimatedCostLabel' => 'Configure fuel price in Settings',
                'priceBasisLabel' => $settings['priceSourceLabel'] ?? 'Configure fuel price in Settings',
                'fuelPriceConfigured' => false,
                'fuelPricePerLiter' => $price,
            ];
        }

        $estimate = round($volume * $price, 2);

        return [
            ...$record,
            'estimatedCost' => $estimate,
            'totalCost' => ((float) ($record['totalCost'] ?? $record['cost'] ?? 0)) > 0
                ? (float) ($record['totalCost'] ?? $record['cost'])
                : $estimate,
            'cost' => ((float) ($record['cost'] ?? $record['totalCost'] ?? 0)) > 0
                ? (float) ($record['cost'] ?? $record['totalCost'])
                : $estimate,
            'estimatedCostLabel' => $this->money($estimate),
            'costLabel' => $this->money(((float) ($record['cost'] ?? $record['totalCost'] ?? 0)) > 0 ? (float) ($record['cost'] ?? $record['totalCost']) : $estimate),
            'priceBasisLabel' => $settings['priceSourceLabel'] ?? 'Manual fuel price',
            'fuelPriceConfigured' => true,
            'fuelPricePerLiter' => $price,
        ];
    }

    private function formatDvirLog(array $log, array $device): array
    {
        return [
            'id' => $this->idFromValue($log),
            'geotabId' => $this->idFromValue(data_get($log, 'device')),
            'vehicle' => $this->plateForDevice($device),
            'driver' => $this->userDisplayName(data_get($log, 'driver')),
            'dateTime' => data_get($log, 'dateTime'),
            'displayDate' => $this->displayDate($this->parseDate(data_get($log, 'dateTime'))),
            'isSafeToOperate' => data_get($log, 'isSafeToOperate') === true,
            'driverRemark' => trim((string) data_get($log, 'driverRemark', '')),
            'repairRemark' => trim((string) data_get($log, 'repairRemark', '')),
            'odometerKm' => round(((float) data_get($log, 'odometer', 0)) / 1000, 2),
            'engineHours' => round(((float) data_get($log, 'engineHours', 0)) / 3600, 2),
        ];
    }

    private function formatFuelTransaction(array $transaction, array $device): array
    {
        $date = $this->parseDate(data_get($transaction, 'dateTime'));
        $volume = (float) data_get($transaction, 'volume', 0);
        $cost = (float) data_get($transaction, 'cost', 0);

        return [
            'id' => $this->idFromValue($transaction),
            'geotabId' => $this->idFromValue(data_get($transaction, 'device')),
            'sourceRecordId' => $this->idFromValue($transaction) ?: substr(md5(json_encode($transaction)), 0, 12),
            'vehicle' => $this->plateForDevice($device),
            'vehicleGeotabId' => $this->idFromValue(data_get($transaction, 'device')),
            'driver' => $this->userDisplayName(data_get($transaction, 'driver')),
            'siteName' => $this->sanitizeText(data_get($transaction, 'siteName', ''), 'Unknown Station'),
            'station' => $this->sanitizeText(data_get($transaction, 'siteName', ''), 'Unknown Station'),
            'stationName' => $this->sanitizeText(data_get($transaction, 'siteName', ''), 'Unknown Station'),
            'stationProvider' => $this->stringValue(data_get($transaction, 'provider')),
            'provider' => $this->stringValue(data_get($transaction, 'provider')),
            'productType' => $this->stringValue(data_get($transaction, 'productType')) ?: 'N/A',
            'dateTime' => $date?->toIso8601String(),
            'displayDate' => $this->displayDate($date),
            'volumeLiters' => round($volume, 2),
            'cost' => round($cost, 2),
            'costLabel' => $this->money($cost),
            'pricePerLiter' => $volume > 0 ? round($cost / $volume, 2) : 0,
            'odometerKm' => round((float) data_get($transaction, 'odometer', 0), 2),
        ];
    }

    private function formatChargeEvent(array $event, array $device): array
    {
        return [
            'id' => $this->idFromValue($event),
            'geotabId' => $this->idFromValue(data_get($event, 'device')),
            'vehicle' => $this->plateForDevice($device),
            'startTime' => data_get($event, 'startTime'),
            'displayDate' => $this->displayDate($this->parseDate(data_get($event, 'startTime'))),
            'duration' => (string) data_get($event, 'duration', ''),
            'energyConsumedKwh' => round((float) data_get($event, 'energyConsumedKwh', 0), 2),
            'peakPowerKw' => round((float) data_get($event, 'peakPowerKw', 0), 2),
            'startStateOfCharge' => data_get($event, 'startStateOfCharge'),
            'endStateOfCharge' => data_get($event, 'endStateOfCharge'),
            'chargeType' => $this->stringValue(data_get($event, 'chargeType')),
            'chargingStartedOdometerKm' => round((float) data_get($event, 'chargingStartedOdometerKm', 0), 2),
            'location' => $this->coordinateParts(data_get($event, 'location')),
        ];
    }

    private function applyTripWorkflow(array $trips): array
    {
        $state = $this->workflowState();
        $customTrips = is_array($state['customTrips'] ?? null) ? $state['customTrips'] : [];
        $overrides = is_array($state['tripOverrides'] ?? null) ? $state['tripOverrides'] : [];

        $merged = [];
        foreach ($trips as $trip) {
            $tripId = (string) ($trip['tripId'] ?? '');
            $override = is_array($overrides[$tripId] ?? null) ? $overrides[$tripId] : [];
            $merged[] = $this->formatWorkflowTrip(array_merge($trip, $override));
        }

        foreach ($customTrips as $tripId => $trip) {
            $override = is_array($overrides[$tripId] ?? null) ? $overrides[$tripId] : [];
            $merged[] = $this->formatWorkflowTrip(array_merge(
                is_array($trip) ? $trip : [],
                $override,
            ));
        }

        usort($merged, fn (array $a, array $b) => strcmp((string) ($b['sortAt'] ?? ''), (string) ($a['sortAt'] ?? '')));

        return $merged;
    }

    private function applyTripAssignments(array $trips, array $vehicles, array $drivers): array
    {
        $vehicleByPlate = [];
        foreach ($vehicles as $index => $vehicle) {
            $plate = strtoupper(trim((string) ($vehicle['plate'] ?? '')));
            if ($plate !== '') {
                $vehicleByPlate[$plate] = $index;
            }
        }

        $driverByName = [];
        foreach ($drivers as $index => $driver) {
            $name = trim((string) ($driver['name'] ?? ''));
            if ($name !== '') {
                $driverByName[$name] = $index;
            }
        }

        foreach ($trips as $trip) {
            $status = strtolower(trim((string) ($trip['status'] ?? '')));
            if (! in_array($status, ['dispatched', 'in progress', 'on trip', 'pending_approval'], true)) {
                continue;
            }

            $plate = strtoupper(trim((string) ($trip['vehicle'] ?? '')));
            if ($plate !== '' && isset($vehicleByPlate[$plate])) {
                $vehicleIndex = $vehicleByPlate[$plate];
                $vehicles[$vehicleIndex]['status'] = 'on trip';
                $vehicles[$vehicleIndex]['statusColor'] = '#4B7BE5';
                $vehicles[$vehicleIndex]['driver'] = trim((string) ($trip['driver'] ?? '')) !== ''
                    ? $trip['driver']
                    : ($vehicles[$vehicleIndex]['driver'] ?? 'Unassigned');
            }

            $driverName = trim((string) ($trip['driver'] ?? ''));
            if ($driverName !== '' && isset($driverByName[$driverName])) {
                $driverIndex = $driverByName[$driverName];
                $drivers[$driverIndex]['status'] = 'on trip';
                $drivers[$driverIndex]['assignedVehicle'] = $plate !== '' ? $plate : ($drivers[$driverIndex]['assignedVehicle'] ?? 'N/A');
            }
        }

        return [$vehicles, $drivers];
    }

    private function formatWorkflowTrip(array $trip): array
    {
        $date = trim((string) ($trip['date'] ?? ''));
        $amount = $trip['amount'] ?? 0;
        $orderValue = $this->parseMoney($trip['orderValue'] ?? $amount);
        $freeDeliveryThreshold = (float) ($trip['freeDeliveryThreshold'] ?? $this->freeDeliveryThresholdForCustomer((string) ($trip['customer'] ?? '')));
        $distanceKm = round((float) ($trip['distanceKm'] ?? 0), 2);
        $status = $this->normalizeWorkflowStatus($trip['status'] ?? 'pending');
        $fulfillmentMethod = $this->fulfillmentMethodForTrip($trip, $orderValue, $distanceKm);
        $workflow = $this->salesDeliveryWorkflowForTrip($trip, $status, $fulfillmentMethod, $orderValue);
        $routeFallback = $this->tripCoordinateFallback($trip);
        $origin = $this->sanitizeText($trip['origin'] ?? '', '');
        $destination = $this->sanitizeText($trip['destination'] ?? '', '');
        $origin = $origin !== '' ? $origin : $routeFallback;
        $destination = $destination !== '' ? $destination : $routeFallback;

        return [
            ...$trip,
            'tripId' => trim((string) ($trip['tripId'] ?? 'TRP-SYNCED')),
            'customer' => trim((string) ($trip['customer'] ?? 'Geotab Trip')),
            'phone' => trim((string) ($trip['phone'] ?? 'N/A')) !== '' ? trim((string) ($trip['phone'] ?? 'N/A')) : 'N/A',
            'origin' => $origin !== '' ? $origin : 'Trip start',
            'destination' => $destination !== '' ? $destination : 'Trip stop',
            'routeText' => ($origin !== '' ? $origin : 'Trip start').' -> '.($destination !== '' ? $destination : 'Trip stop'),
            'routeFallback' => $routeFallback,
            'cargoType' => $this->sanitizeText($trip['cargoType'] ?? '', 'General'),
            'vehicle' => trim((string) ($trip['vehicle'] ?? '')),
            'driver' => trim((string) ($trip['driver'] ?? '')),
            'status' => $status,
            'amount' => is_numeric($amount) ? $this->money((float) $amount) : (trim((string) $amount) !== '' ? (string) $amount : $this->money(0)),
            'orderValue' => $orderValue,
            'orderValueLabel' => $this->money($orderValue),
            'totalWeightKg' => isset($trip['totalWeightKg']) ? round((float) $trip['totalWeightKg'], 2) : null,
            'scheduledDepartureAt' => $trip['scheduledDepartureAt'] ?? null,
            'estimatedArrivalAt' => $trip['estimatedArrivalAt'] ?? null,
            'specialInstructions' => $this->sanitizeText($trip['specialInstructions'] ?? '', ''),
            'freeDeliveryCandidate' => ($trip['freeDeliveryCandidate'] ?? false) === true || $orderValue >= $freeDeliveryThreshold,
            'freeDeliveryThreshold' => $freeDeliveryThreshold,
            'freeDeliveryThresholdLabel' => $this->money($freeDeliveryThreshold),
            'cancellationReason' => $this->sanitizeText($trip['cancellationReason'] ?? '', ''),
            'cancelledAt' => $trip['cancelledAt'] ?? null,
            'fulfillmentMethod' => $fulfillmentMethod,
            'fulfillmentLabel' => $this->fulfillmentLabel($fulfillmentMethod),
            'salesChannel' => $this->sanitizeText($trip['salesChannel'] ?? '', 'Viber'),
            'quotationStatus' => $this->sanitizeText($trip['quotationStatus'] ?? '', 'order_confirmed'),
            'poReceived' => ($trip['poReceived'] ?? true) !== false,
            'workflowPhase' => $workflow['phase'],
            'workflowPhaseLabel' => $workflow['phaseLabel'],
            'workflowPhaseNumber' => $workflow['phaseNumber'],
            'workflowGroup' => $workflow['group'],
            'workflowNextAction' => $workflow['nextAction'],
            'clientWorkflowStatus' => $workflow['clientStatus'],
            'clientWorkflowMilestone' => $workflow['clientMilestone'],
            'workflowSteps' => $workflow['steps'],
            'date' => $date !== '' ? $date : $this->displayDate(now()),
            'notes' => trim((string) ($trip['notes'] ?? '')),
            'delay' => trim((string) ($trip['delay'] ?? '')),
            'hasDelay' => ($trip['hasDelay'] ?? false) === true,
            'distanceKm' => $distanceKm,
            'averageSpeed' => round((float) ($trip['averageSpeed'] ?? 0), 1),
            'maximumSpeed' => round((float) ($trip['maximumSpeed'] ?? 0), 1),
            'drivingMinutes' => (int) ($trip['drivingMinutes'] ?? 0),
            'idlingMinutes' => (int) ($trip['idlingMinutes'] ?? 0),
            'startedAt' => $trip['startedAt'] ?? null,
            'endedAt' => $trip['endedAt'] ?? null,
            'startPoint' => $trip['startPoint'] ?? null,
            'stopPoint' => $trip['stopPoint'] ?? null,
            'routeName' => $trip['routeName'] ?? null,
            'routedPlaces' => is_array($trip['routedPlaces'] ?? null) ? $trip['routedPlaces'] : [],
            'currentZone' => $trip['currentZone'] ?? null,
            'originZone' => $trip['originZone'] ?? null,
            'destinationZone' => $trip['destinationZone'] ?? null,
            'arrivalState' => $trip['arrivalState'] ?? 'pending',
            'arrivedAtDestination' => ($trip['arrivedAtDestination'] ?? false) === true,
            'sortAt' => $trip['sortAt'] ?? now()->toIso8601String(),
        ];
    }

    private function workflowTripUpdates(Request $request): array
    {
        $updates = [];
        foreach ([
            'customer',
            'phone',
            'origin',
            'destination',
            'cargoType',
            'vehicle',
            'driver',
            'driverId',
            'assignedDriverId',
            'notes',
            'specialInstructions',
            'fulfillmentMethod',
            'salesChannel',
            'quotationStatus',
            'routeGeotabId',
            'deviceGeotabId',
            'cancellationReason',
        ] as $field) {
            if ($request->has($field)) {
                $updates[$field] = $this->sanitizeText($request->input($field, ''), '');
            }
        }

        if ($request->has('poReceived')) {
            $updates['poReceived'] = filter_var($request->input('poReceived'), FILTER_VALIDATE_BOOL);
        }
        if ($request->has('status')) {
            $updates['status'] = $this->normalizeWorkflowStatus($request->input('status', 'pending'));
        }
        if ($request->has('amount')) {
            $updates['amount'] = $request->input('amount', 0);
        }
        if ($request->has('orderValue')) {
            $updates['orderValue'] = $request->input('orderValue', 0);
        }
        if ($request->has('totalWeightKg')) {
            $updates['totalWeightKg'] = $request->input('totalWeightKg');
        }
        if ($request->has('scheduledDepartureAt')) {
            $updates['scheduledDepartureAt'] = $request->input('scheduledDepartureAt');
            $updates['date'] = $this->displayDate(Carbon::parse((string) $request->input('scheduledDepartureAt')));
        }
        if ($request->has('estimatedArrivalAt')) {
            $updates['estimatedArrivalAt'] = $request->input('estimatedArrivalAt');
        }
        if ($request->has('freeDeliveryCandidate')) {
            $updates['freeDeliveryCandidate'] = filter_var($request->input('freeDeliveryCandidate'), FILTER_VALIDATE_BOOL);
        }
        if ($request->has('workflowPhaseNumber')) {
            $updates['workflowPhaseNumber'] = max(1, min(12, (int) $request->input('workflowPhaseNumber')));
            $updates['workflowPhaseLocked'] = true;
        } elseif ($request->has('status')) {
            $updates['workflowPhaseLocked'] = false;
        }
        if ($request->has('startedAt')) {
            $updates['startedAt'] = $request->input('startedAt');
        }
        if ($request->has('endedAt')) {
            $updates['endedAt'] = $request->input('endedAt');
        }
        if ($request->has('cancelledAt')) {
            $updates['cancelledAt'] = $request->input('cancelledAt');
        }
        if (($updates['status'] ?? '') === 'completed') {
            $updates['endedAt'] = $updates['endedAt'] ?? now()->toIso8601String();
            $updates['arrivalState'] = 'completed';
            $updates['arrivedAtDestination'] = true;
        } elseif (($updates['status'] ?? '') === 'cancelled') {
            $updates['cancelledAt'] = $updates['cancelledAt'] ?? now()->toIso8601String();
            $updates['arrivalState'] = 'cancelled';
            $updates['arrivedAtDestination'] = false;
        } elseif (($updates['status'] ?? '') === 'pending_approval') {
            $updates['arrivalState'] = 'pending_approval';
        } elseif (($updates['status'] ?? '') === 'dispatched') {
            $updates['startedAt'] = $updates['startedAt'] ?? now()->toIso8601String();
            $phaseNumber = (int) ($updates['workflowPhaseNumber'] ?? 10);
            $updates['arrivalState'] = $phaseNumber >= 11 ? 'arrived' : 'enroute';
            $updates['arrivedAtDestination'] = $phaseNumber >= 11;
        }
        $updates['sortAt'] = now()->toIso8601String();

        return $updates;
    }

    private function workflowTransitionError(Request $request, array $trip): ?string
    {
        $phase = isset($trip['workflowPhaseNumber'])
            ? max(1, min(12, (int) $trip['workflowPhaseNumber']))
            : null;
        $status = $this->normalizeWorkflowStatus($trip['status'] ?? 'pending');
        $driver = trim((string) ($trip['driver'] ?? ''));
        $vehicle = trim((string) ($trip['vehicle'] ?? ''));

        if ($phase !== null && $phase >= 10 && ($driver === '' || $vehicle === '')) {
            return 'A driver and vehicle are required before a trip can start dispatch.';
        }

        $requestsCompletion = $status === 'completed' || $phase === 12;
        $hasCompletionTimestamp = trim((string) $request->input('endedAt', '')) !== '';
        if ($requestsCompletion && ! $hasCompletionTimestamp) {
            return 'Trip completion must go through POD review; dispatch phase updates cannot complete a trip.';
        }

        return null;
    }

    private function queueWorkflowPhaseWriteBack(string $tripId, array $trip, int $phaseNumber): void
    {
        if ($phaseNumber < 10 || ! $this->writeBack->tableAvailable()) {
            return;
        }

        $routeId = trim((string) ($trip['routeGeotabId'] ?? $trip['geotabRouteId'] ?? $trip['routeId'] ?? ''));
        $deviceId = trim((string) ($trip['deviceGeotabId'] ?? $trip['assignedVehicleGeotabId'] ?? ''));
        if ($routeId === '' || $deviceId === '') {
            return;
        }

        $this->writeBack->createJob(
            'route.assign_device',
            'Route',
            [
                'routeId' => $routeId,
                'deviceId' => $deviceId,
                'name' => trim((string) ($trip['routeName'] ?? '')),
                'source' => 'workflow_phase_'.$phaseNumber,
            ],
            'trip',
            $tripId,
            'workflow-phase:'.$tripId.':route.assign_device:'.$phaseNumber.':'.$routeId.':'.$deviceId,
            'dispatcher',
        );
    }

    private function normalizeWorkflowStatus(mixed $status): string
    {
        return match (strtolower(trim((string) $status))) {
            'dispatched', 'on trip', 'ontrip', 'in progress', 'inprogress' => 'dispatched',
            'pending approval', 'pending_approval' => 'pending_approval',
            'completed' => 'completed',
            'cancelled', 'canceled' => 'cancelled',
            default => 'pending',
        };
    }

    private function fulfillmentMethodForTrip(array $trip, float $orderValue, float $distanceKm): string
    {
        $method = strtolower(trim((string) ($trip['fulfillmentMethod'] ?? '')));
        if (in_array($method, ['free_delivery', 'pickup', 'client_pickup', 'paid_delivery'], true)) {
            return $method;
        }

        if ($orderValue >= 100000) {
            return 'free_delivery';
        }

        if ($distanceKm <= 0 && $orderValue > 0) {
            return 'client_pickup';
        }

        return 'pickup';
    }

    private function fulfillmentLabel(string $method): string
    {
        return match ($method) {
            'free_delivery' => 'Free delivery',
            'client_pickup' => 'Client pickup option',
            'paid_delivery' => 'Paid delivery',
            default => 'Pickup',
        };
    }

    private function salesDeliveryWorkflowForTrip(
        array $trip,
        string $status,
        string $fulfillmentMethod,
        float $orderValue,
    ): array {
        $poReceived = ($trip['poReceived'] ?? true) !== false;
        $hasAssignment = trim((string) ($trip['vehicle'] ?? '')) !== '' || trim((string) ($trip['driver'] ?? '')) !== '';
        $isCompleted = $status === 'completed';
        $isDispatched = $status === 'dispatched';
        $hasArrived = $isCompleted
            || ($trip['arrivedAtDestination'] ?? false) === true
            || in_array(strtolower(trim((string) ($trip['arrivalState'] ?? ''))), ['arrived', 'completed'], true);
        $isDelivery = in_array($fulfillmentMethod, ['free_delivery', 'paid_delivery'], true);
        $explicitPhaseNumber = ($trip['workflowPhaseLocked'] ?? false) === true && isset($trip['workflowPhaseNumber'])
            ? max(1, min(12, (int) $trip['workflowPhaseNumber']))
            : null;

        $steps = [
            [
                'key' => 'inquiry',
                'label' => 'Inquiry received',
                'phase' => 'sales',
                'status' => 'done',
                'owner' => 'Sales',
                'detail' => 'Client inquiry captured from Viber or sales channel.',
            ],
            [
                'key' => 'stock_check',
                'label' => 'Stock availability checked',
                'phase' => 'sales',
                'status' => 'done',
                'owner' => 'Sales',
                'detail' => 'Availability confirmed before quotation.',
            ],
            [
                'key' => 'quotation',
                'label' => 'Quotation sent',
                'phase' => 'sales',
                'status' => $poReceived ? 'done' : 'active',
                'owner' => 'Sales',
                'detail' => 'Quotation is sent through Viber and waits for PO confirmation.',
            ],
            [
                'key' => 'po_confirmation',
                'label' => 'PO received',
                'phase' => 'sales',
                'status' => $poReceived ? 'done' : 'blocked',
                'owner' => 'Sales',
                'detail' => $poReceived ? 'Order confirmed for fulfillment.' : 'Follow up or revise quote.',
            ],
            [
                'key' => 'fulfillment_strategy',
                'label' => 'Fulfillment method selected',
                'phase' => 'logistics',
                'status' => $poReceived ? 'done' : 'pending',
                'owner' => 'Logistics',
                'detail' => $this->fulfillmentLabel($fulfillmentMethod).' based on order value '.$this->money($orderValue).'.',
            ],
            [
                'key' => 'service_advisor_request',
                'label' => 'Delivery request to Service Advisor',
                'phase' => 'logistics',
                'status' => $isDelivery ? ($hasAssignment || $isDispatched || $isCompleted ? 'done' : 'active') : 'not_required',
                'owner' => 'Service Advisor',
                'detail' => 'Client, address, date, amount, weight, vehicle, and driver should be confirmed.',
            ],
            [
                'key' => 'assignment',
                'label' => 'Vehicle and driver assigned',
                'phase' => 'logistics',
                'status' => $hasAssignment ? 'done' : ($isDelivery ? 'active' : 'not_required'),
                'owner' => 'Dispatch',
                'detail' => $hasAssignment ? 'Assigned resources are ready.' : 'Vehicle and driver are still TBA.',
            ],
            [
                'key' => 'client_eta',
                'label' => 'ETA and receiving schedule confirmed',
                'phase' => 'execution',
                'status' => $isDispatched || $isCompleted ? 'done' : ($hasAssignment ? 'active' : 'pending'),
                'owner' => 'Coordinator',
                'detail' => 'Coordinate departure time and confirm preferred receiving schedule.',
            ],
            [
                'key' => 'driver_briefing',
                'label' => 'Driver briefing and invoice handoff',
                'phase' => 'execution',
                'status' => $isDispatched || $isCompleted ? 'done' : ($hasAssignment ? 'active' : 'pending'),
                'owner' => 'Dispatch',
                'detail' => 'Provide invoice, signing requirements, and document copy instructions.',
            ],
            [
                'key' => 'dispatch',
                'label' => 'Delivery dispatched',
                'phase' => 'execution',
                'status' => $isCompleted || $hasArrived ? 'done' : ($isDispatched ? 'active' : ($isDelivery ? 'pending' : 'not_required')),
                'owner' => 'Driver',
                'detail' => 'Driver departs and live tracking begins.',
            ],
            [
                'key' => 'arrival',
                'label' => 'Arrival at client location',
                'phase' => 'execution',
                'status' => $isCompleted ? 'done' : ($hasArrived ? 'active' : 'pending'),
                'owner' => 'Driver',
                'detail' => 'Sales notifies client through Viber on arrival.',
            ],
            [
                'key' => 'pod',
                'label' => 'Delivery complete and POD confirmed',
                'phase' => 'completion',
                'status' => $isCompleted ? 'done' : 'pending',
                'owner' => 'Client / Driver',
                'detail' => 'Client receives and signs documents, driver confirms completion to Sales, and POD is recorded.',
            ],
        ];

        if ($explicitPhaseNumber !== null) {
            foreach ($steps as $index => &$step) {
                $phaseNumber = min($index + 1, 12);
                $step['status'] = match (true) {
                    $phaseNumber < $explicitPhaseNumber => 'done',
                    $phaseNumber === $explicitPhaseNumber => $explicitPhaseNumber === 12 ? 'done' : 'active',
                    default => 'pending',
                };
            }
            unset($step);
        }

        $active = collect($steps)->first(fn (array $step): bool => in_array($step['status'], ['blocked', 'active'], true));
        $phaseNumber = $explicitPhaseNumber ?? $this->workflowPhaseNumberFromSteps($steps, $isCompleted);
        $phase = $this->workflowPhaseSlug($phaseNumber, (string) ($active['phase'] ?? ($isCompleted ? 'completion' : 'logistics')));
        $nextAction = (string) ($active['detail'] ?? $this->workflowPhaseMilestone($phaseNumber));

        return [
            'phase' => $phase,
            'phaseNumber' => $phaseNumber,
            'group' => $this->workflowGroupForPhase($phaseNumber),
            'phaseLabel' => match ($phase) {
                'request' => 'Trip request',
                'assignment' => 'Dispatch assignment',
                'ready' => 'Ready to dispatch',
                'transit' => 'In transit',
                'arrived' => 'Arrived / POD needed',
                'execution' => 'Delivery execution',
                'completion' => 'Completion & POD',
                default => 'Fulfillment strategy',
            },
            'nextAction' => $nextAction,
            'clientStatus' => $this->clientWorkflowStatus($phaseNumber),
            'clientMilestone' => $this->clientWorkflowMilestone($phaseNumber),
            'steps' => $steps,
        ];
    }

    private function workflowPhaseNumberFromSteps(array $steps, bool $isCompleted): int
    {
        if ($isCompleted) {
            return 12;
        }

        foreach ($steps as $index => $step) {
            if (in_array((string) ($step['status'] ?? ''), ['blocked', 'active'], true)) {
                return min($index + 1, 12);
            }
        }

        return 7;
    }

    private function workflowPhaseSlug(int $phaseNumber, string $fallback): string
    {
        return match (true) {
            $phaseNumber <= 2 => 'request',
            $phaseNumber <= 6 => 'assignment',
            $phaseNumber <= 9 => 'ready',
            $phaseNumber === 10 => 'transit',
            $phaseNumber === 11 => 'arrived',
            $phaseNumber >= 12 => 'completion',
            default => $fallback,
        };
    }

    private function workflowGroupForPhase(int $phaseNumber): string
    {
        return match (true) {
            $phaseNumber <= 2 => 'Pending Details',
            $phaseNumber <= 6 => 'Pending Assignment',
            $phaseNumber <= 9 => 'Ready to Dispatch',
            $phaseNumber === 10 => 'In Transit',
            $phaseNumber === 11 => 'Arrived / POD Needed',
            default => 'Completed / POD Review Handoff',
        };
    }

    private function workflowPhaseMilestone(int $phaseNumber): string
    {
        return match (true) {
            $phaseNumber <= 2 => 'Complete the delivery trip details.',
            $phaseNumber <= 6 => 'Assign vehicle, driver, and dispatch notification.',
            $phaseNumber <= 9 => 'Start dispatch when driver and vehicle are ready.',
            $phaseNumber === 10 => 'Mark arrived when the vehicle reaches the destination.',
            $phaseNumber === 11 => 'Waiting for POD/admin review before completion.',
            default => 'Accounting reviews billing after POD verification.',
        };
    }

    private function clientWorkflowStatus(int $phaseNumber): string
    {
        return match (true) {
            $phaseNumber <= 2 => 'Your delivery request is being prepared',
            $phaseNumber <= 6 => 'Your order is being prepared',
            $phaseNumber <= 9 => 'Your delivery is being arranged',
            $phaseNumber === 10 => 'Your delivery is on its way',
            $phaseNumber === 11 => 'Your delivery has arrived',
            default => 'Delivery complete',
        };
    }

    private function clientWorkflowMilestone(int $phaseNumber): string
    {
        return match (true) {
            $phaseNumber <= 2 => 'Next: Pioneer confirms the delivery details.',
            $phaseNumber <= 6 => 'Next: Pioneer confirms items, quotation, and order details.',
            $phaseNumber <= 9 => 'Next: Pioneer assigns the vehicle, driver, and delivery schedule.',
            $phaseNumber === 10 => 'Next: Track the truck as it travels to your location.',
            $phaseNumber === 11 => 'Next: Receive, sign, and confirm delivery documents.',
            default => 'Thank you. Proof of delivery has been recorded.',
        };
    }

    private function workflowState(): array
    {
        $state = Cache::get('geotab_workflow_state_v1', []);
        $customTrips = is_array($state['customTrips'] ?? null) ? $state['customTrips'] : [];

        if (Schema::hasTable('fleet_trips')) {
            foreach (FleetTrip::query()->get(['trip_id', 'payload']) as $trip) {
                if (is_array($trip->payload)) {
                    $customTrips[$trip->trip_id] = $trip->payload;
                }
            }
        }

        return [
            'customTrips' => $customTrips,
            'tripOverrides' => is_array($state['tripOverrides'] ?? null) ? $state['tripOverrides'] : [],
        ];
    }

    private function storeWorkflowState(array $state): void
    {
        $customTrips = is_array($state['customTrips'] ?? null) ? $state['customTrips'] : [];

        if (Schema::hasTable('fleet_trips')) {
            foreach ($customTrips as $tripId => $payload) {
                if (! is_array($payload)) {
                    continue;
                }

                FleetTrip::query()->updateOrCreate(
                    ['trip_id' => (string) $tripId],
                    [
                        'status' => (string) ($payload['status'] ?? 'pending'),
                        'workflow_phase_number' => (int) ($payload['workflowPhaseNumber'] ?? 1),
                        'customer' => (string) ($payload['customer'] ?? 'Unknown Client'),
                        'driver' => trim((string) ($payload['driver'] ?? '')) ?: null,
                        'vehicle' => trim((string) ($payload['vehicle'] ?? '')) ?: null,
                        'scheduled_departure_at' => $payload['scheduledDepartureAt'] ?? null,
                        'cancelled_at' => $payload['cancelledAt'] ?? null,
                        'payload' => $payload,
                    ],
                );
            }
        }

        Cache::put('geotab_workflow_state_v1', [
            'customTrips' => $customTrips,
            'tripOverrides' => is_array($state['tripOverrides'] ?? null) ? $state['tripOverrides'] : [],
        ], now()->addDays(7));
    }

    private function clearFleetCaches(): void
    {
        Cache::forget(self::SNAPSHOT_FRESH_KEY);
        Cache::forget(self::SNAPSHOT_STALE_KEY);
        Cache::forget(self::LIVE_FRESH_KEY);
        Cache::forget(self::LIVE_STALE_KEY);
        Cache::forget(self::ANALYTICS_SUMMARY_KEY);
        Cache::forget(self::MAINTENANCE_SUMMARY_KEY);
        Cache::forget(self::DASHBOARD_SUMMARY_KEY);
        Cache::forget(self::MAINTENANCE_PREDICTIONS_KEY);
        Cache::forget(self::DRIVER_PERFORMANCE_KEY);
        Cache::forget(self::VEHICLE_HEALTH_KEY);
        Cache::forget(self::ROUTE_EFFICIENCY_KEY);
        Cache::forget(self::TRIP_FORECAST_KEY);
        Cache::forget(self::FUEL_TREND_KEY);
    }

    private function buildStatementOfAccounts(array $billings): array
    {
        $clients = [];

        foreach ($billings as $invoice) {
            $client = trim((string) ($invoice['client'] ?? 'Unknown Client'));
            $amount = $this->parseMoney($invoice['amount'] ?? 0);
            $status = strtolower((string) ($invoice['status'] ?? 'issued'));
            if (! in_array($status, ['issued', 'sent', 'paid', 'overdue'], true)) {
                continue;
            }

            $clients[$client] ??= [
                'name' => $client,
                'invoices' => 0,
                'invoiceRows' => [],
                'totalBilled' => 0.0,
                'paid' => 0.0,
                'overdue' => 0.0,
                'outstanding' => 0.0,
                'latestInvoiceDate' => '',
                'oldestUnpaid' => null,
            ];

            $clients[$client]['invoices']++;
            if (in_array($status, ['issued', 'sent', 'paid', 'overdue'], true)) {
                $clients[$client]['totalBilled'] += $amount;
            }
            if ($status === 'paid') {
                $clients[$client]['paid'] += $amount;
            } elseif ($status === 'overdue') {
                $clients[$client]['overdue'] += $amount;
                $clients[$client]['outstanding'] += $amount;
            } elseif (in_array($status, ['issued', 'sent'], true)) {
                $clients[$client]['outstanding'] += $amount;
            }
            $clients[$client]['invoiceRows'][] = [
                ...$invoice,
                'destination' => $invoice['destination'] ?? $invoice['routeDestination'] ?? '',
                'voidReason' => $invoice['voidReason'] ?? null,
            ];
            if (in_array($status, ['issued', 'sent', 'overdue'], true)) {
                $invoiceDate = (string) ($invoice['issueDate'] ?? '');
                $clients[$client]['oldestUnpaid'] = $clients[$client]['oldestUnpaid'] === null
                    ? $invoiceDate
                    : min((string) $clients[$client]['oldestUnpaid'], $invoiceDate);
            }
            $clients[$client]['latestInvoiceDate'] = max(
                (string) $clients[$client]['latestInvoiceDate'],
                (string) ($invoice['issueDate'] ?? ''),
            );
        }

        $rows = array_values(array_map(function (array $client): array {
            return [
                ...$client,
                'total' => $this->money((float) $client['totalBilled']),
                'paidLabel' => $this->money((float) $client['paid']),
                'overdueLabel' => $this->money((float) $client['overdue']),
                'outstandingLabel' => $this->money((float) $client['outstanding']),
                'oldestUnpaid' => $client['oldestUnpaid'],
            ];
        }, $clients));

        usort($rows, fn (array $a, array $b) => ((float) ($b['outstanding'] ?? 0)) <=> ((float) ($a['outstanding'] ?? 0)));

        return [
            'overview' => [
                'clients' => count($rows),
                'totalOutstanding' => round(array_sum(array_map(fn (array $row): float => (float) ($row['outstanding'] ?? 0), $rows)), 2),
                'totalPaid' => round(array_sum(array_map(fn (array $row): float => (float) ($row['paid'] ?? 0), $rows)), 2),
                'totalOverdue' => round(array_sum(array_map(fn (array $row): float => (float) ($row['overdue'] ?? 0), $rows)), 2),
                'grandTotal' => round(array_sum(array_map(fn (array $row): float => (float) ($row['totalBilled'] ?? 0), $rows)), 2),
                'grandTotalLabel' => $this->money(array_sum(array_map(fn (array $row): float => (float) ($row['totalBilled'] ?? 0), $rows))),
            ],
            'clients' => $rows,
        ];
    }

    private function billingContextPayload(): array
    {
        return [
            'title' => 'Delivery Trip Billing',
            'label' => 'PioneerPath delivery trip charges only',
            'note' => 'GeoTab subscriptions, monthly fees, onboarding, activation, overtime, and contract fees are managed through the Pioneer ERP system separately.',
            'erpServiceBillingItems' => [
                'GeoTab monthly subscription fees',
                'On-boarding and activation fees',
                'Overtime fees',
                'Contract fees',
            ],
            'pioneerPathScope' => 'PioneerPath billing covers delivery trip charges, POD readiness, delivery fee review, optional ERP references, and VAT breakdown only.',
            'vatRatePercent' => $this->billingVatRatePercent(),
        ];
    }

    private function billingSnapshot(): array
    {
        $snapshot = $this->snapshot();
        $tripsById = [];

        foreach (is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [] as $trip) {
            if (! is_array($trip)) {
                continue;
            }
            $tripId = trim((string) ($trip['tripId'] ?? $trip['geotabId'] ?? ''));
            if ($tripId !== '') {
                $tripsById[$tripId] = $trip;
            }
        }

        $workflow = $this->workflowState();
        foreach (is_array($workflow['customTrips'] ?? null) ? $workflow['customTrips'] : [] as $trip) {
            if (! is_array($trip)) {
                continue;
            }
            $formatted = $this->formatWorkflowTrip($trip);
            $tripId = trim((string) ($formatted['tripId'] ?? ''));
            if ($tripId !== '') {
                $tripsById[$tripId] = $formatted;
            }
        }

        $trips = array_values($tripsById);
        $billingsByTrip = [];
        foreach (is_array($snapshot['billings'] ?? null) ? $snapshot['billings'] : [] as $invoice) {
            if (! is_array($invoice)) {
                continue;
            }
            $tripId = trim((string) ($invoice['tripId'] ?? ''));
            if ($tripId !== '') {
                $billingsByTrip[$tripId] = $invoice;
            }
        }

        foreach ($trips as $trip) {
            $tripId = trim((string) ($trip['tripId'] ?? ''));
            if ($tripId === '' || ! $this->tripBillableForEstimate($trip)) {
                continue;
            }
            $billingsByTrip[$tripId] = $this->itemizedInvoiceForTrip($trip, false, is_array($snapshot['fuel'] ?? null) ? $snapshot['fuel'] : []);
        }

        $billings = array_values($billingsByTrip);

        return [
            ...$snapshot,
            'trips' => $trips,
            'billings' => $billings,
            'billingOverview' => $this->billingOverviewForInvoices($billings),
        ];
    }

    private function syncAutomatedBillingForTripId(string $tripId, string $reason): void
    {
        if (! $this->billingInvoiceReferencesTableAvailable()) {
            return;
        }

        $snapshot = $this->billingSnapshot();
        $trip = $this->findTrip($snapshot['trips'] ?? [], $tripId);
        if ($trip === null) {
            return;
        }

        $this->syncAutomatedBillingForTrip($trip, $reason, is_array($snapshot['fuel'] ?? null) ? $snapshot['fuel'] : []);
    }

    private function syncAutomatedBillingForTrip(array $trip, string $reason, ?array $fuel = null): void
    {
        if (! $this->billingInvoiceReferencesTableAvailable() || ! $this->tripBillableForEstimate($trip)) {
            return;
        }

        $tripId = trim((string) ($trip['tripId'] ?? ''));
        if ($tripId === '') {
            return;
        }

        $invoice = $this->itemizedInvoiceForTrip($trip, true, $fuel ?? []);
        $reference = BillingInvoiceReference::query()->firstOrNew(['trip_id' => $tripId]);
        $currentStatus = strtolower((string) ($reference->status ?: 'draft'));
        if (in_array($currentStatus, ['approved', 'issued', 'paid', 'overdue', 'voided'], true)) {
            return;
        }

        $meta = is_array($reference->meta) ? $reference->meta : [];
        $meta['automatedBilling'] = [
            'reason' => $this->sanitizeText($reason, 'automated billing sync'),
            'calculationStatus' => $invoice['calculationStatus'] ?? 'draft_estimate',
            'podReadiness' => $invoice['podReadiness'] ?? 'Draft estimate',
            'evidenceSummary' => $invoice['evidenceSummary'] ?? [],
            'reviewFlags' => $invoice['reviewFlags'] ?? [],
            'manifest' => $invoice['manifest'] ?? [],
            'lastCalculatedAt' => $invoice['lastCalculatedAt'] ?? now()->toIso8601String(),
        ];

        $updates = [
            'invoice_number' => $reference->invoice_number ?: ($invoice['invoiceNumber'] ?? 'INV-'.substr($tripId, -6)),
            'status' => $reference->status ?: 'draft',
            'meta' => $meta,
        ];

        if (! $reference->exists) {
            $updates['status_history'] = $this->appendInvoiceStatusHistory([], null, 'draft', 'automated draft estimate created', 'system', ['automatedBilling' => true]);
        } elseif (! (bool) $reference->manual_invoice && $currentStatus === 'draft') {
            $updates['status_history'] = $this->appendInvoiceStatusHistory(
                is_array($reference->status_history) ? $reference->status_history : [],
                'draft',
                'draft',
                'automated billing estimate refreshed',
                'system',
                ['automatedBilling' => true, 'reason' => $reason],
            );
        }

        if (! (bool) $reference->manual_invoice && $currentStatus === 'draft') {
            $updates['line_items'] = $this->normalizedInvoiceLineItems($invoice['chargeBreakdown'] ?? $invoice['itemizedBreakdown'] ?? []);
        }

        $reference->fill($updates)->save();
        $this->clearFleetCaches();
    }

    private function tripBillableForEstimate(array $trip): bool
    {
        $tripId = trim((string) ($trip['tripId'] ?? ''));
        $status = strtolower(trim((string) ($trip['status'] ?? '')));
        $amount = $this->parseMoney($trip['amount'] ?? 0);
        $orderValue = $this->parseMoney($trip['orderValue'] ?? $trip['declaredValue'] ?? 0);

        return $tripId !== ''
            && ($amount > 0 || $orderValue > 0)
            && in_array($status, ['dispatched', 'in_progress', 'in progress', 'on trip', 'ontrip', 'completed', 'delivered', 'closed', 'verified'], true);
    }

    private function applyInvoiceReferences(array $invoices): array
    {
        if (! $this->billingInvoiceReferencesTableAvailable()) {
            return array_map(function (array $invoice): array {
                return $this->withBillingStage([
                    ...$invoice,
                    'references' => $this->emptyInvoiceReference((string) ($invoice['tripId'] ?? ''), (string) ($invoice['invoiceNumber'] ?? '')),
                ]);
            }, $invoices);
        }

        $tripIds = collect($invoices)
            ->map(fn (array $invoice): string => (string) ($invoice['tripId'] ?? ''))
            ->filter()
            ->values()
            ->all();

        $references = BillingInvoiceReference::query()
            ->whereIn('trip_id', $tripIds)
            ->get()
            ->keyBy('trip_id');

        return array_map(function (array $invoice) use ($references): array {
            $tripId = (string) ($invoice['tripId'] ?? '');
            $reference = $references->get($tripId);
            $formatted = $reference instanceof BillingInvoiceReference
                ? $this->formatInvoiceReference($reference)
                : $this->emptyInvoiceReference($tripId, (string) ($invoice['invoiceNumber'] ?? ''));
            if ($reference instanceof BillingInvoiceReference) {
                $invoice = $this->applyBillingReferenceFinancials($invoice, $reference);
            }

            $merged = [
                ...$invoice,
                'invoiceNumber' => $formatted['invoiceNumber'] ?: ($invoice['invoiceNumber'] ?? null),
                'status' => $formatted['status'] ?: ($invoice['status'] ?? 'draft'),
                'manualInvoice' => $formatted['manualInvoice'],
                'overrideReason' => $formatted['overrideReason'],
                'erpReference' => $formatted['erpReference'],
                'poNumber' => $formatted['poNumber'],
                'drNumber' => $formatted['drNumber'],
                'referenceNotes' => $formatted['notes'],
                'statusHistory' => $formatted['statusHistory'],
                'approvalNote' => $formatted['approvalNote'],
                'approvedAt' => $formatted['approvedAt'],
                'approvedBy' => $formatted['approvedBy'],
                'rejectionReason' => $formatted['rejectionReason'],
                'rejectedAt' => $formatted['rejectedAt'],
                'rejectedBy' => $formatted['rejectedBy'],
                'finalChargeBasis' => $formatted['finalChargeBasis'],
                'issuedAt' => $formatted['issuedAt'],
                'issuedBy' => $formatted['issuedBy'],
                'paymentReference' => $formatted['paymentReference'],
                'paymentDate' => $formatted['paymentDate'],
                'paidAt' => $formatted['paidAt'],
                'paidBy' => $formatted['paidBy'],
                'voidedAt' => $formatted['voidedAt'],
                'voidReason' => $formatted['voidReason'],
                'references' => $formatted,
            ];

            return $this->withBillingStage($merged);
        }, $invoices);
    }

    private function withBillingStage(array $invoice): array
    {
        $status = strtolower(trim((string) ($invoice['status'] ?? 'draft')));
        $podStatus = strtolower(trim((string) ($invoice['podStatus'] ?? 'missing')));
        $podReady = (bool) ($invoice['podReady'] ?? false);
        $calculationStatus = strtolower(trim((string) ($invoice['calculationStatus'] ?? 'draft_estimate')));
        $reviewFlags = is_array($invoice['reviewFlags'] ?? null) ? $invoice['reviewFlags'] : [];
        $blockingReasons = [];

        if (! $podReady) {
            $blockingReasons[] = match ($podStatus) {
                'submitted' => 'POD is waiting for admin review.',
                'rejected' => 'POD was rejected and must be corrected.',
                default => 'Verified POD is required before billing approval.',
            };
        }
        foreach ($reviewFlags as $flag) {
            if (is_array($flag) && trim((string) ($flag['message'] ?? '')) !== '') {
                $blockingReasons[] = (string) $flag['message'];
            }
        }

        [$stage, $stageLabel] = match (true) {
            $status === 'voided' => ['voided', 'Voided'],
            $status === 'paid' => ['paid', 'Paid'],
            $status === 'overdue' => ['overdue', 'Overdue'],
            in_array($status, ['issued', 'sent'], true) => ['issued', 'Issued'],
            $status === 'approved' => ['approved', 'Approved'],
            $status === 'rejected' => ['rejected', 'Rejected'],
            $podStatus === 'submitted' && ! $podReady => ['pod_under_review', 'POD under admin review'],
            $podStatus === 'rejected' && ! $podReady => ['pod_rejected', 'POD correction required'],
            $calculationStatus === 'waiting_for_pod' || ! $podReady => ['waiting_for_pod', 'Waiting for POD'],
            $calculationStatus === 'review_required' => ['review_required', 'Needs billing review'],
            $calculationStatus === 'ready_for_review' => ['ready_for_review', 'Ready for billing review'],
            default => ['draft_estimate', 'Draft estimate'],
        };

        $nextAllowedActions = match ($stage) {
            'pod_under_review' => ['verify_pod', 'reject_pod'],
            'ready_for_review', 'review_required' => ['approve', 'reject', 'recalculate', 'add_toll_evidence'],
            'approved' => ['issue', 'reject'],
            'issued', 'overdue' => ['mark_paid'],
            'draft_estimate', 'waiting_for_pod', 'pod_rejected' => ['recalculate', 'edit_references'],
            default => [],
        };

        return [
            ...$invoice,
            'billingStage' => $stage,
            'billingStageLabel' => $stageLabel,
            'podReviewStatus' => $podStatus,
            'blockingReasons' => array_values(array_unique(array_filter($blockingReasons))),
            'nextAllowedActions' => $nextAllowedActions,
        ];
    }

    private function clientSafeInvoiceSummaryForTrip(array $trip): array
    {
        if (! $this->tripBillableForEstimate($trip)) {
            return [
                'publicStatus' => 'Billing not started',
                'stageLabel' => 'Not ready',
                'visibleToClient' => false,
                'message' => 'Delivery billing starts after dispatch details are complete.',
            ];
        }

        $invoice = $this->applyInvoiceReferences([
            $this->itemizedInvoiceForTrip($trip, false),
        ])[0] ?? [];
        $status = strtolower(trim((string) ($invoice['status'] ?? 'draft')));
        $stage = strtolower(trim((string) ($invoice['billingStage'] ?? 'draft_estimate')));
        $issuedVisible = in_array($status, ['issued', 'sent', 'paid', 'overdue'], true);

        $publicStatus = match (true) {
            $status === 'paid' => 'Paid',
            $status === 'overdue' => 'Payment overdue',
            in_array($status, ['issued', 'sent'], true) => 'Invoice issued',
            $stage === 'pod_under_review' => 'Proof of delivery under review',
            $stage === 'pod_rejected' => 'Proof of delivery needs correction',
            $stage === 'waiting_for_pod' => 'Waiting for proof of delivery',
            default => 'Invoice being prepared',
        };

        return [
            'publicStatus' => $publicStatus,
            'stageLabel' => $this->sanitizeText($invoice['billingStageLabel'] ?? $publicStatus, $publicStatus),
            'visibleToClient' => true,
            'invoiceNumber' => $issuedVisible ? ($invoice['invoiceNumber'] ?? null) : null,
            'amount' => $issuedVisible ? ($invoice['totalWithVat'] ?? $invoice['amount'] ?? null) : null,
            'amountLabel' => $issuedVisible ? (string) ($invoice['amount'] ?? $invoice['totalWithVat'] ?? '') : null,
            'message' => $issuedVisible
                ? 'Accounting has released the delivery invoice summary.'
                : 'Accounting will release invoice details after internal review.',
        ];
    }

    private function applyBillingReferenceFinancials(array $invoice, BillingInvoiceReference $reference): array
    {
        $lineItems = is_array($reference->line_items) ? $reference->line_items : [];
        if ($lineItems !== []) {
            $normalized = $this->normalizedInvoiceLineItems($lineItems);
            $subtotal = round(array_sum(array_map(fn (array $row): float => (float) ($row['amount'] ?? 0), $normalized)), 2);
            $vatRatePercent = $this->billingVatRatePercent();
            $vatAmount = round($subtotal * ($vatRatePercent / 100), 2);
            $total = round($subtotal + $vatAmount, 2);

            $invoice = [
                ...$invoice,
                'itemizedBreakdown' => $normalized,
                'subtotal' => $this->money($subtotal),
                'subtotalBeforeVat' => $this->money($subtotal),
                'vatRatePercent' => $vatRatePercent,
                'vatAmount' => $vatAmount,
                'vat' => $this->money($vatAmount),
                'totalWithVat' => $this->money($total),
                'amount' => $this->money($total),
                'total' => $this->money($total),
                'source' => 'Manual accounting override linked to trip '.$reference->trip_id,
            ];
        }

        $overrides = is_array($reference->overrides) ? $reference->overrides : [];
        foreach (['baseCharge', 'distanceCharge', 'fuelCostEstimate', 'surcharges'] as $key) {
            if (array_key_exists($key, $overrides)) {
                $value = round(max(0, (float) $overrides[$key]), 2);
                $invoice[$key] = $this->money($value);
            }
        }

        return $invoice;
    }

    private function formatInvoiceReference(BillingInvoiceReference $reference): array
    {
        $meta = $this->billingInvoiceMeta($reference);

        return [
            'tripId' => $reference->trip_id,
            'invoiceNumber' => $reference->invoice_number,
            'erpReference' => $reference->erp_reference,
            'poNumber' => $reference->po_number,
            'drNumber' => $reference->dr_number,
            'notes' => $reference->notes,
            'status' => $reference->status ?: 'draft',
            'manualInvoice' => (bool) $reference->manual_invoice,
            'overrideReason' => $reference->override_reason,
            'lineItems' => $reference->line_items ?? [],
            'overrides' => $reference->overrides ?? [],
            'statusHistory' => $reference->status_history ?? [],
            'approvalNote' => $meta['approvalNote'],
            'approvedAt' => $meta['approvedAt'],
            'approvedBy' => $meta['approvedBy'],
            'rejectionReason' => $meta['rejectionReason'],
            'rejectedAt' => $meta['rejectedAt'],
            'rejectedBy' => $meta['rejectedBy'],
            'finalChargeBasis' => $meta['finalChargeBasis'],
            'issuedAt' => $meta['issuedAt'],
            'issuedBy' => $meta['issuedBy'],
            'paymentReference' => $meta['paymentReference'],
            'paymentDate' => $meta['paymentDate'],
            'paidAt' => $meta['paidAt'],
            'paidBy' => $meta['paidBy'],
            'voidedAt' => $reference->voided_at?->toIso8601String(),
            'voidReason' => $reference->void_reason,
            'meta' => $reference->meta ?? [],
            'updatedAt' => $reference->updated_at?->toIso8601String(),
        ];
    }

    private function emptyInvoiceReference(string $tripId, string $invoiceNumber): array
    {
        return [
            'tripId' => $tripId,
            'invoiceNumber' => $invoiceNumber,
            'erpReference' => null,
            'poNumber' => null,
            'drNumber' => null,
            'notes' => null,
            'status' => null,
            'manualInvoice' => false,
            'overrideReason' => null,
            'lineItems' => [],
            'overrides' => [],
            'statusHistory' => [],
            'approvalNote' => null,
            'approvedAt' => null,
            'approvedBy' => null,
            'rejectionReason' => null,
            'rejectedAt' => null,
            'rejectedBy' => null,
            'finalChargeBasis' => null,
            'issuedAt' => null,
            'issuedBy' => null,
            'paymentReference' => null,
            'paymentDate' => null,
            'paidAt' => null,
            'paidBy' => null,
            'voidedAt' => null,
            'voidReason' => null,
            'meta' => [],
            'updatedAt' => null,
        ];
    }

    private function billingInvoiceMeta(BillingInvoiceReference $reference): array
    {
        $meta = is_array($reference->meta) ? $reference->meta : [];

        return [
            'approvalNote' => $this->nullableCleanText($meta['approvalNote'] ?? null),
            'approvedAt' => $this->nullableCleanText($meta['approvedAt'] ?? null),
            'approvedBy' => $this->nullableCleanText($meta['approvedBy'] ?? null),
            'rejectionReason' => $this->nullableCleanText($meta['rejectionReason'] ?? null),
            'rejectedAt' => $this->nullableCleanText($meta['rejectedAt'] ?? null),
            'rejectedBy' => $this->nullableCleanText($meta['rejectedBy'] ?? null),
            'finalChargeBasis' => $this->nullableCleanText($meta['finalChargeBasis'] ?? null),
            'issuedAt' => $this->nullableCleanText($meta['issuedAt'] ?? null),
            'issuedBy' => $this->nullableCleanText($meta['issuedBy'] ?? null),
            'paymentReference' => $this->nullableCleanText($meta['paymentReference'] ?? null),
            'paymentDate' => $this->nullableCleanText($meta['paymentDate'] ?? null),
            'paidAt' => $this->nullableCleanText($meta['paidAt'] ?? null),
            'paidBy' => $this->nullableCleanText($meta['paidBy'] ?? null),
        ];
    }

    private function billingVatRatePercent(): float
    {
        if (! Schema::hasTable('system_settings') || ! Schema::hasColumn('system_settings', 'vat_rate_percent')) {
            return 12.0;
        }

        $rate = (float) (SystemSetting::query()->first()?->vat_rate_percent ?? 12.0);

        return round(max(0.0, min(100.0, $rate)), 2);
    }

    private function vehicleSubscriptionCoveragePayload(): array
    {
        $billingMonth = now()->format('F Y');
        $groups = [];
        $seenPlates = [];

        if ($this->clientAssignmentsTableAvailable()) {
            ClientVehicleAssignment::query()
                ->where('status', 'active')
                ->orderBy('client_name')
                ->orderBy('vehicle_plate')
                ->get()
                ->each(function (ClientVehicleAssignment $assignment) use (&$groups, &$seenPlates): void {
                    $client = $this->sanitizeText($assignment->client_name, 'Unassigned Client');
                    $plate = $this->sanitizeText($assignment->vehicle_plate, '');
                    if ($plate === '') {
                        return;
                    }

                    $groups[$client] ??= [];
                    $groups[$client][] = $plate;
                    $seenPlates[strtoupper($plate)] = true;
                });
        }

        foreach (($this->snapshot()['vehicles'] ?? []) as $vehicle) {
            $plate = $this->sanitizeText(
                $vehicle['plate'] ?? $vehicle['licensePlate'] ?? $vehicle['name'] ?? '',
                '',
            );
            if ($plate === '' || isset($seenPlates[strtoupper($plate)])) {
                continue;
            }

            $status = strtolower((string) ($vehicle['status'] ?? 'active'));
            if (in_array($status, ['inactive', 'deactivated', 'retired'], true)) {
                continue;
            }

            $client = $this->sanitizeText(
                $vehicle['client'] ?? $vehicle['customer'] ?? $vehicle['assignedClient'] ?? '',
                'Unassigned Client',
            );
            $groups[$client] ??= [];
            $groups[$client][] = $plate;
            $seenPlates[strtoupper($plate)] = true;
        }

        ksort($groups);
        $rows = array_map(function (string $client, array $plates): array {
            $uniquePlates = array_values(array_unique(array_filter($plates)));
            sort($uniquePlates);

            return [
                'client' => $client,
                'count' => count($uniquePlates),
                'plates' => $uniquePlates,
                'copyText' => $this->numberedPlateText($uniquePlates),
            ];
        }, array_keys($groups), $groups);

        return [
            'title' => 'Vehicle Subscription Coverage',
            'purpose' => 'ERP reference report for GeoTab subscription billing plate descriptions. No PioneerPath invoice is created from this report.',
            'billingMonth' => $billingMonth,
            'generatedAt' => now()->toIso8601String(),
            'totalClients' => count($rows),
            'totalVehicles' => array_sum(array_map(fn (array $row): int => (int) $row['count'], $rows)),
            'groups' => $rows,
        ];
    }

    private function numberedPlateText(array $plates): string
    {
        return collect($plates)
            ->values()
            ->map(fn (string $plate, int $index): string => ($index + 1).'. '.$plate)
            ->implode(' ');
    }

    private function filterBillingInvoices(array $invoices, Request $request): array
    {
        $status = strtolower(trim((string) $request->query('status', '')));
        $client = strtolower(trim((string) $request->query('client', '')));
        $tripId = strtolower(trim((string) $request->query('tripId', '')));
        $search = strtolower(trim((string) ($request->query('q', $request->query('search', '')))));
        $podReadiness = strtolower(trim((string) ($request->query('podReadiness', $request->query('podReady', '')))));
        $dateFrom = $this->parseDate($request->query('dateFrom'));
        $dateTo = $this->parseDate($request->query('dateTo'));

        return array_values(array_filter($invoices, function (array $invoice) use ($status, $client, $tripId, $search, $podReadiness, $dateFrom, $dateTo): bool {
            if ($status !== '' && $status !== 'all' && strtolower((string) ($invoice['status'] ?? 'draft')) !== $status) {
                return false;
            }
            if ($client !== '' && ! str_contains(strtolower((string) ($invoice['client'] ?? '')), $client)) {
                return false;
            }
            if ($tripId !== '' && ! str_contains(strtolower((string) ($invoice['tripId'] ?? '')), $tripId)) {
                return false;
            }
            if ($search !== '') {
                $haystack = strtolower(implode(' ', [
                    $invoice['invoiceNumber'] ?? '',
                    $invoice['client'] ?? '',
                    $invoice['tripId'] ?? '',
                    $invoice['erpReference'] ?? '',
                    $invoice['poNumber'] ?? '',
                    $invoice['drNumber'] ?? '',
                ]));
                if (! str_contains($haystack, $search)) {
                    return false;
                }
            }
            if ($podReadiness !== '' && $podReadiness !== 'all') {
                $ready = (bool) ($invoice['podReady'] ?? false);
                $manualReview = (bool) ($invoice['manualReviewRequired'] ?? false);
                if (in_array($podReadiness, ['1', 'true', 'ready', 'ready_to_bill', 'pod_ready'], true) && ! $ready) {
                    return false;
                }
                if (in_array($podReadiness, ['0', 'false', 'hold', 'hold_for_pod', 'pod_hold'], true) && $ready) {
                    return false;
                }
                if (in_array($podReadiness, ['review', 'needs_review'], true) && ! $manualReview) {
                    return false;
                }
            }

            $issueDate = $this->parseDate($invoice['issueDate'] ?? null);
            if ($dateFrom !== null && ($issueDate === null || $issueDate->lt($dateFrom->startOfDay()))) {
                return false;
            }
            if ($dateTo !== null && ($issueDate === null || $issueDate->gt($dateTo->endOfDay()))) {
                return false;
            }

            return true;
        }));
    }

    private function billingOverviewForInvoices(array $billings): array
    {
        $monthStart = now()->startOfMonth();
        $monthEnd = now()->endOfMonth();
        $currentMonthBillings = array_values(array_filter($billings, function (array $invoice) use ($monthStart, $monthEnd): bool {
            $date = $this->parseDate($invoice['issueDate'] ?? null);

            return $date !== null && $date->betweenIncluded($monthStart, $monthEnd);
        }));

        return [
            'totalBilled' => round(array_sum(array_map(fn (array $invoice): float => in_array(strtolower((string) ($invoice['status'] ?? 'draft')), ['issued', 'sent', 'paid', 'overdue'], true) ? $this->parseMoney($invoice['amount'] ?? 0) : 0.0, $billings)), 2),
            'totalPaid' => round(array_sum(array_map(function (array $invoice): float {
                return strtolower((string) ($invoice['status'] ?? 'issued')) === 'paid' ? $this->parseMoney($invoice['amount'] ?? 0) : 0.0;
            }, $billings)), 2),
            'totalSent' => round(array_sum(array_map(function (array $invoice): float {
                return in_array(strtolower((string) ($invoice['status'] ?? 'issued')), ['sent', 'issued'], true) ? $this->parseMoney($invoice['amount'] ?? 0) : 0.0;
            }, $billings)), 2),
            'totalOverdue' => round(array_sum(array_map(function (array $invoice): float {
                return strtolower((string) ($invoice['status'] ?? 'issued')) === 'overdue' ? $this->parseMoney($invoice['amount'] ?? 0) : 0.0;
            }, $billings)), 2),
            'totalInvoicedThisMonth' => round(array_sum(array_map(fn (array $invoice): float => in_array(strtolower((string) ($invoice['status'] ?? 'draft')), ['issued', 'sent', 'paid', 'overdue'], true) ? $this->parseMoney($invoice['amount'] ?? 0) : 0.0, $currentMonthBillings)), 2),
            'totalCollectedThisMonth' => round(array_sum(array_map(function (array $invoice): float {
                return strtolower((string) ($invoice['status'] ?? 'issued')) === 'paid' ? $this->parseMoney($invoice['amount'] ?? 0) : 0.0;
            }, $currentMonthBillings)), 2),
            'outstandingBalance' => round(array_sum(array_map(function (array $invoice): float {
                return in_array(strtolower((string) ($invoice['status'] ?? 'issued')), ['issued', 'sent', 'overdue'], true)
                    ? $this->parseMoney($invoice['amount'] ?? 0)
                    : 0.0;
            }, $billings)), 2),
            'overdueAmount' => round(array_sum(array_map(function (array $invoice): float {
                return strtolower((string) ($invoice['status'] ?? 'issued')) === 'overdue' ? $this->parseMoney($invoice['amount'] ?? 0) : 0.0;
            }, $billings)), 2),
            'invoiceCount' => count($billings),
        ] + $this->billingIntelligenceOverview($billings);
    }

    private function normalizedInvoiceLineItems(array $items): array
    {
        return array_values(array_map(function (array $item): array {
            $amount = round(max(0, (float) ($item['amount'] ?? 0)), 2);

            return [
                'label' => $this->sanitizeText($item['label'] ?? 'Manual charge', 'Manual charge'),
                'amount' => $amount,
                'amountLabel' => $this->money($amount),
                'source' => $this->sanitizeText($item['source'] ?? 'manual', 'manual'),
                'confidence' => $this->sanitizeText($item['confidence'] ?? 'manual', 'manual'),
                'note' => $this->sanitizeText($item['note'] ?? '', ''),
            ];
        }, $items));
    }

    private function validateInvoiceStatusRequirements(Request $request, array $trip, array $invoice, string $nextStatus, array $validated): ?JsonResponse
    {
        if ($nextStatus === 'rejected' && trim((string) ($validated['rejectionReason'] ?? '')) === '') {
            return $this->respondError('Rejection reason is required when rejecting an invoice.', 422);
        }

        if ($nextStatus === 'approved' && trim((string) ($validated['approvalNote'] ?? '')) === '') {
            return $this->respondError('Approval note is required before an invoice can be approved.', 422);
        }

        if ($nextStatus === 'issued' && trim((string) ($validated['finalChargeBasis'] ?? '')) === '') {
            return $this->respondError('Final charge basis is required before an invoice can be issued.', 422);
        }

        if ($nextStatus === 'paid' && trim((string) ($validated['paymentReference'] ?? '')) === '') {
            return $this->respondError('Payment reference is required before an invoice can be marked paid.', 422);
        }

        if (in_array($nextStatus, ['approved', 'issued', 'paid', 'overdue'], true)) {
            if (! $this->tripCompletedForBilling($trip)) {
                return $this->respondError('Invoice cannot move forward until the linked trip is completed.', 422);
            }
            if (! (bool) ($invoice['podReady'] ?? false)) {
                return $this->respondError('Invoice cannot move forward until proof of delivery is verified.', 422);
            }
        }

        return null;
    }

    private function tripCompletedForBilling(array $trip): bool
    {
        $status = strtolower(trim((string) ($trip['status'] ?? '')));

        return in_array($status, ['completed', 'delivered', 'closed', 'verified'], true);
    }

    private function invoiceActorFromRequest(Request $request): string
    {
        $actor = trim((string) (
            $request->input('actor')
            ?? $request->header('X-Pioneer-User')
            ?? $request->header('X-User-Name')
            ?? $request->header('X-Pioneer-Role')
            ?? 'accounting staff'
        ));

        return $this->sanitizeText($actor, 'accounting staff');
    }

    private function invoiceMetaForStatus(string $status, array $validated, array $meta, Request $request): array
    {
        $actor = $this->invoiceActorFromRequest($request);
        $now = now()->toIso8601String();

        if ($status === 'approved') {
            $meta['approvalNote'] = $this->nullableCleanText($validated['approvalNote'] ?? null);
            $meta['approvedAt'] = $now;
            $meta['approvedBy'] = $actor;
        }

        if ($status === 'rejected') {
            $meta['rejectionReason'] = $this->nullableCleanText($validated['rejectionReason'] ?? null);
            $meta['rejectedAt'] = $now;
            $meta['rejectedBy'] = $actor;
        }

        if ($status === 'issued') {
            $meta['finalChargeBasis'] = $this->nullableCleanText($validated['finalChargeBasis'] ?? null);
            $meta['issuedAt'] = $now;
            $meta['issuedBy'] = $actor;
        }

        if ($status === 'paid') {
            $meta['paymentReference'] = $this->nullableCleanText($validated['paymentReference'] ?? null);
            $meta['paymentDate'] = isset($validated['paymentDate'])
                ? Carbon::parse($validated['paymentDate'])->toDateString()
                : now()->toDateString();
            $meta['paidAt'] = $now;
            $meta['paidBy'] = $actor;
        }

        if ($status === 'overdue') {
            $meta['overdueAt'] = $now;
            $meta['overdueBy'] = $actor;
        }

        return $meta;
    }

    private function invoiceLifecycleNote(string $status, array $validated, string $fallback): string
    {
        $note = match ($status) {
            'approved' => $validated['approvalNote'] ?? $fallback,
            'rejected' => $validated['rejectionReason'] ?? $fallback,
            'issued' => $validated['finalChargeBasis'] ?? $fallback,
            'paid' => isset($validated['paymentReference']) ? 'payment reference: '.$validated['paymentReference'] : $fallback,
            default => $fallback,
        };

        return $this->sanitizeText($note, $fallback);
    }

    private function appendInvoiceStatusHistory(
        array $history,
        ?string $from,
        string $to,
        string $note,
        string $actor = 'system',
        array $context = [],
    ): array {
        $history[] = [
            'from' => $from,
            'to' => $to,
            'note' => $this->sanitizeText($note, 'status updated'),
            'actor' => $this->sanitizeText($actor, 'system'),
            'at' => now()->toIso8601String(),
            'context' => $context,
        ];

        return array_values($history);
    }

    private function validInvoiceStatusTransition(string $from, string $to): bool
    {
        if ($from === $to) {
            return true;
        }

        $allowed = [
            'draft' => ['approved', 'rejected'],
            'rejected' => ['draft', 'approved'],
            'approved' => ['issued', 'rejected'],
            'issued' => ['paid', 'overdue'],
            'sent' => ['paid', 'overdue'],
            'overdue' => ['paid'],
        ];

        return in_array($to, $allowed[$from] ?? [], true);
    }

    private function itemizedInvoiceForTrip(array $trip, bool $recalculated = false, ?array $fuel = null): array
    {
        $amount = $this->parseMoney($trip['amount'] ?? '0');
        $distanceKm = (float) ($trip['distanceKm'] ?? 0);
        $issueDate = $this->normalizeDateString($trip['date'] ?? $trip['endedAt'] ?? now()->toDateString());
        $dueDate = Carbon::parse($issueDate)->addDays(30)->toDateString();
        $invoiceNumber = 'INV-'.substr((string) ($trip['tripId'] ?? 'TRIP'), -6);
        $pod = $this->loadPod((string) ($trip['tripId'] ?? ''));
        $reference = $this->billingInvoiceReferencesTableAvailable()
            ? BillingInvoiceReference::query()->where('trip_id', (string) ($trip['tripId'] ?? ''))->first()
            : null;
        $referenceMeta = is_array($reference?->meta) ? $reference->meta : [];
        $calculation = $this->tripBillingCalculator->calculate($trip, [
            'settings' => [
                'baseDeliveryChargePerKm' => (float) $this->systemSettingsValue('base_delivery_charge_per_km', 65),
                'fuelSurchargeRatePercent' => (float) $this->systemSettingsValue('fuel_surcharge_rate_percent', 15),
                'vatRatePercent' => $this->billingVatRatePercent(),
                'freeDeliveryThreshold' => $this->freeDeliveryThresholdForCustomer((string) ($trip['customer'] ?? '')),
            ],
            'fuel' => is_array($fuel) ? $fuel : [],
            'pod' => $pod,
            'manualTolls' => is_array($referenceMeta['manualTolls'] ?? null) ? $referenceMeta['manualTolls'] : [],
        ]);

        $podReady = (bool) ($calculation['podReady'] ?? false);
        $manualReviewRequired = (bool) ($calculation['manualReviewRequired'] ?? false);
        $tripCompleted = $this->tripCompletedForBilling($trip);
        $computedStatus = (! $tripCompleted || ! $podReady)
            ? 'draft'
            : (Carbon::parse($dueDate)->lt(now()->startOfDay()) ? 'overdue' : 'issued');

        return [
            'id' => $invoiceNumber,
            'invoiceNumber' => $invoiceNumber,
            'client' => $this->sanitizeText($trip['customer'] ?? '', 'Unknown Client'),
            'tripId' => (string) ($trip['tripId'] ?? ''),
            'origin' => $this->sanitizeText($trip['origin'] ?? '', 'Trip start'),
            'destination' => $this->sanitizeText($trip['destination'] ?? '', 'Trip stop'),
            'issueDate' => $issueDate,
            'dueDate' => $dueDate,
            'status' => $computedStatus,
            'amount' => $this->money((float) ($calculation['totalWithVat'] ?? 0)),
            'total' => $this->money((float) ($calculation['totalWithVat'] ?? 0)),
            'baseRate' => $this->money((float) ($calculation['baseCharge'] ?? 0)),
            'baseCharge' => $this->money((float) ($calculation['baseCharge'] ?? 0)),
            'distanceCost' => $this->money((float) ($calculation['distanceCharge'] ?? 0)),
            'distanceCharge' => $this->money((float) ($calculation['distanceCharge'] ?? 0)),
            'fuelCost' => $this->money((float) ($calculation['fuelCharge'] ?? 0)),
            'fuelCostEstimate' => $this->money((float) ($calculation['fuelCharge'] ?? 0)),
            'tollCost' => $this->money((float) ($calculation['tollCharge'] ?? 0)),
            'tollEstimate' => $this->money((float) ($calculation['tollCharge'] ?? 0)),
            'surcharges' => $this->money((float) ($calculation['surcharges'] ?? 0)),
            'itemizedBreakdown' => $this->normalizedInvoiceLineItems($calculation['itemizedBreakdown'] ?? []),
            'chargeBreakdown' => $this->normalizedInvoiceLineItems($calculation['chargeBreakdown'] ?? []),
            'deliverySubtotal' => $this->money((float) ($calculation['baseCharge'] ?? 0) + (float) ($calculation['distanceCharge'] ?? 0) + (float) ($calculation['fuelCharge'] ?? 0)),
            'subtotal' => $this->money((float) ($calculation['subtotal'] ?? 0)),
            'subtotalBeforeVat' => $this->money((float) ($calculation['subtotal'] ?? 0)),
            'serviceFee' => $this->money((float) ($calculation['surcharges'] ?? 0)),
            'vatRatePercent' => (float) ($calculation['vatRatePercent'] ?? $this->billingVatRatePercent()),
            'vatAmount' => (float) ($calculation['vatAmount'] ?? 0),
            'vat' => $this->money((float) ($calculation['vatAmount'] ?? 0)),
            'totalWithVat' => $this->money((float) ($calculation['totalWithVat'] ?? 0)),
            'discount' => $this->money(0, negative: true),
            'erpReference' => null,
            'poNumber' => null,
            'drNumber' => null,
            'referenceNotes' => null,
            'orderValue' => (float) ($trip['orderValue'] ?? $trip['declaredValue'] ?? $amount),
            'orderValueLabel' => $this->money((float) ($trip['orderValue'] ?? $trip['declaredValue'] ?? $amount)),
            'distanceKm' => round($distanceKm, 2),
            'baseDeliveryChargePerKm' => (float) ($calculation['baseDeliveryChargePerKm'] ?? 0),
            'fuelSurchargeRatePercent' => (float) ($calculation['fuelSurchargeRatePercent'] ?? 0),
            'freeDeliveryCandidate' => (bool) ($calculation['freeDeliveryCandidate'] ?? false),
            'freeDeliveryThreshold' => (float) ($calculation['freeDeliveryThreshold'] ?? 0),
            'freeDeliveryThresholdLabel' => $this->money((float) ($calculation['freeDeliveryThreshold'] ?? 0)),
            'withinFreeDeliveryRadius' => (bool) ($calculation['withinFreeDeliveryRadius'] ?? false),
            'thirdPartyCandidate' => (bool) ($calculation['thirdPartyCandidate'] ?? false),
            'manualReviewRequired' => $manualReviewRequired,
            'podReady' => $podReady,
            'podStatus' => (string) ($calculation['podStatus'] ?? 'missing'),
            'podReadiness' => (string) ($calculation['podReadiness'] ?? 'Draft estimate'),
            'collectionReadiness' => (string) ($calculation['podReadiness'] ?? 'Draft estimate'),
            'calculationStatus' => (string) ($calculation['calculationStatus'] ?? 'draft_estimate'),
            'pricingModel' => $this->invoicePricingModel((bool) ($calculation['freeDeliveryCandidate'] ?? false), (bool) ($calculation['thirdPartyCandidate'] ?? false), $manualReviewRequired),
            'billingDecision' => $this->invoiceBillingDecision((bool) ($calculation['freeDeliveryCandidate'] ?? false), (bool) ($calculation['thirdPartyCandidate'] ?? false), $podReady),
            'pricingRules' => $this->invoicePricingRules((bool) ($calculation['freeDeliveryCandidate'] ?? false), (bool) ($calculation['withinFreeDeliveryRadius'] ?? false), (bool) ($calculation['thirdPartyCandidate'] ?? false), $podReady),
            'evidenceSummary' => $calculation['evidenceSummary'] ?? [],
            'reviewFlags' => $calculation['reviewFlags'] ?? [],
            'manifest' => $calculation['manifest'] ?? [],
            'lastCalculatedAt' => $calculation['lastCalculatedAt'] ?? now()->toIso8601String(),
            'clientTrackingIncluded' => true,
            'recalculated' => $recalculated,
            'source' => str_contains((string) ($trip['notes'] ?? ''), 'dispatch workflow')
                ? 'Derived from application dispatch workflow'
                : 'Derived from synced Geotab trip distance',
        ];
    }

    private function billingIntelligenceOverview(array $billings): array
    {
        $freeDeliveryCandidates = count(array_filter(
            $billings,
            fn (array $invoice): bool => (bool) ($invoice['freeDeliveryCandidate'] ?? false),
        ));
        $podReady = count(array_filter(
            $billings,
            fn (array $invoice): bool => (bool) ($invoice['podReady'] ?? false),
        ));
        $manualReview = count(array_filter(
            $billings,
            fn (array $invoice): bool => (bool) ($invoice['manualReviewRequired'] ?? false),
        ));
        $thirdParty = count(array_filter(
            $billings,
            fn (array $invoice): bool => (bool) ($invoice['thirdPartyCandidate'] ?? false),
        ));

        return [
            'freeDeliveryCandidates' => $freeDeliveryCandidates,
            'podReadyCount' => $podReady,
            'podHoldCount' => max(0, count($billings) - $podReady),
            'manualReviewCount' => $manualReview,
            'thirdPartyCandidateCount' => $thirdParty,
            'billingPolicy' => [
                'freeDeliveryRule' => 'Candidate for waived delivery when order value is ₱100,000+ and route distance is within 10 km of the office.',
                'thirdPartyRule' => 'AP Cargo, Lalamove, courier, and outsourced routes are flagged as client pass-through review items.',
                'podRule' => 'Collection readiness requires uploaded POD evidence such as signature, photo, or delivery confirmation.',
            ],
        ];
    }

    private function invoicePricingModel(bool $freeDeliveryCandidate, bool $thirdPartyCandidate, bool $manualReviewRequired): string
    {
        if ($thirdPartyCandidate) {
            return 'Third-party pass-through review';
        }

        if ($freeDeliveryCandidate) {
            return 'Free-delivery candidate';
        }

        return $manualReviewRequired ? 'Manual dispatch quote review' : 'Distance, fuel, and service charge';
    }

    private function invoiceBillingDecision(bool $freeDeliveryCandidate, bool $thirdPartyCandidate, bool $podReady): string
    {
        if (! $podReady) {
            return 'Hold collection until POD is verified.';
        }

        if ($thirdPartyCandidate) {
            return 'Confirm pass-through third-party delivery fee with client.';
        }

        if ($freeDeliveryCandidate) {
            return 'Eligible for free-delivery approval review.';
        }

        return 'Ready for normal invoice collection.';
    }

    private function invoicePricingRules(
        bool $freeDeliveryCandidate,
        bool $withinFreeDeliveryRadius,
        bool $thirdPartyCandidate,
        bool $podReady,
    ): array {
        return [
            [
                'label' => 'Free delivery',
                'state' => $freeDeliveryCandidate ? 'candidate' : ($withinFreeDeliveryRadius ? 'distance ok' : 'not eligible'),
                'detail' => 'Order reaches the configured free-delivery threshold and within 10 km requires approval before waiving delivery fees.',
            ],
            [
                'label' => 'Third-party routes',
                'state' => $thirdPartyCandidate ? 'review' : 'clear',
                'detail' => 'AP Cargo, Lalamove, and outsourced delivery fees stay visible for client pass-through.',
            ],
            [
                'label' => 'Proof of delivery',
                'state' => $podReady ? 'verified' : 'required',
                'detail' => 'Signature, photo, or uploaded confirmation should be present before collection.',
            ],
        ];
    }

    private function buildUnmatchedRoutesReport(array $historicalTrips, array $liveTrips): array
    {
        $rows = [];
        foreach (array_merge($liveTrips, $historicalTrips) as $trip) {
            $routeStops = (array) ($trip['routedPlaces'] ?? []);
            $currentZone = trim((string) ($trip['currentZone'] ?? ''));
            $destinationZone = trim((string) ($trip['destinationZone'] ?? ''));
            $hasRoute = $routeStops !== [];
            $matched = $hasRoute && ($currentZone === '' || $destinationZone === '' || $currentZone === $destinationZone);

            if ($matched) {
                continue;
            }

            $rows[] = [
                'tripId' => $trip['tripId'] ?? 'TRP-SYNCED',
                'vehicle' => $trip['vehicle'] ?? 'N/A',
                'driver' => $trip['driver'] ?? 'Unassigned',
                'routeName' => $trip['routeName'] ?? 'Unassigned route',
                'currentZone' => $currentZone !== '' ? $currentZone : 'Outside zone',
                'destinationZone' => $destinationZone !== '' ? $destinationZone : 'No planned destination',
                'status' => $trip['status'] ?? 'pending',
                'date' => $trip['date'] ?? 'N/A',
            ];
        }

        return $rows;
    }

    private function buildDriverCongregationReport(array $statusList, array $zones, array $deviceIndex): array
    {
        $groups = [];

        foreach ($statusList as $status) {
            $zoneName = $this->zoneNameForCoordinate(
                (float) data_get($status, 'latitude', 0),
                (float) data_get($status, 'longitude', 0),
                $zones,
            );

            if ($zoneName === null || trim($zoneName) === '') {
                continue;
            }

            $driver = $this->userDisplayName(data_get($status, 'driver'));
            if ($driver === '') {
                continue;
            }

            $device = $deviceIndex[$this->idFromValue(data_get($status, 'device'))] ?? [];
            $groups[$zoneName][] = [
                'driver' => $driver,
                'vehicle' => $this->plateForDevice($device),
                'dateTime' => data_get($status, 'dateTime'),
                'isDriving' => data_get($status, 'isDriving') === true,
            ];
        }

        $rows = [];
        foreach ($groups as $zoneName => $entries) {
            if (count($entries) < 2) {
                continue;
            }

            $rows[] = [
                'zone' => $zoneName,
                'drivers' => count($entries),
                'vehicles' => array_values(array_unique(array_map(fn (array $entry): string => (string) ($entry['vehicle'] ?? 'N/A'), $entries))),
                'entries' => $entries,
                'lastSeenAt' => max(array_map(fn (array $entry): string => (string) ($entry['dateTime'] ?? ''), $entries)),
            ];
        }

        usort($rows, fn (array $a, array $b) => strcmp((string) ($b['lastSeenAt'] ?? ''), (string) ($a['lastSeenAt'] ?? '')));

        return $rows;
    }

    private function notificationState(): array
    {
        $state = Cache::get('geotab_notification_state_v1', []);
        if (! is_array($state)) {
            return ['read' => [], 'deleted' => []];
        }

        return [
            'read' => is_array($state['read'] ?? null) ? $state['read'] : [],
            'deleted' => is_array($state['deleted'] ?? null) ? $state['deleted'] : [],
        ];
    }

    private function notificationPayload(): array
    {
        $notifications = [];

        try {
            $snapshot = $this->snapshot();
            $notifications = is_array($snapshot['notifications'] ?? null)
                ? $snapshot['notifications']
                : [];
        } catch (\Throwable $e) {
            Log::channel('app_errors')->warning('PioneerPath notifications snapshot unavailable; falling back to stored notification history', [
                'errorType' => get_class($e),
                'errorMessage' => $e->getMessage(),
            ]);
        }

        $notifications = $this->mergeStoredNotifications($notifications);

        return $this->applyNotificationState($notifications);
    }

    private function managedUsersTableAvailable(): bool
    {
        return Schema::hasTable('users')
            && Schema::hasColumn('users', 'role')
            && Schema::hasColumn('users', 'status')
            && Schema::hasColumn('users', 'activity_log');
    }

    private function formatManagedUser(User $user, bool $includeActivity = false): array
    {
        $role = $this->normalizeManagedUserRole($user->role ?? 'driver');
        $status = $this->normalizeManagedUserStatus($user->status ?? 'active');
        $payload = [
            'id' => (string) $user->id,
            'username' => Str::before((string) $user->email, '@') ?: (string) $user->email,
            'fullName' => $this->sanitizeText($user->name, 'User'),
            'name' => $this->sanitizeText($user->name, 'User'),
            'email' => (string) $user->email,
            'phone' => $user->phone,
            'role' => $role,
            'roleLabel' => self::MANAGED_USER_ROLES[$role] ?? 'Driver',
            'appRole' => $this->managedUserAppRole($role),
            'status' => $status,
            'isActive' => $status === 'active',
            'mustChangePassword' => (bool) ($user->must_change_password ?? false),
            'lastLoginAt' => $user->last_login_at?->toIso8601String(),
            'createdAt' => $user->created_at?->toIso8601String(),
            'updatedAt' => $user->updated_at?->toIso8601String(),
            'deactivatedAt' => $user->deactivated_at?->toIso8601String(),
            'createdBy' => $user->created_by,
        ];

        if ($includeActivity) {
            $payload['activityLog'] = array_values(is_array($user->activity_log) ? $user->activity_log : []);
        }

        if ($role === 'driver') {
            $driver = $this->linkedManualDriverForUser($user);
            if ($driver !== null) {
                $payload['driverProfile'] = $this->formatDriverAccountProfile($driver);
                $payload['assignedVehicle'] = $driver->assigned_vehicle_plate ?: null;
            } else {
                $payload['driverProfile'] = null;
                $payload['driverProfileMissing'] = true;
            }
        }

        return $payload;
    }

    private function linkedManualDriverForUser(User $user): ?ManualDriver
    {
        if (! $this->manualDriversTableAvailable()) {
            return null;
        }

        if (Schema::hasColumn('manual_drivers', 'user_id')) {
            $linked = ManualDriver::query()->where('user_id', $user->id)->first();
            if ($linked !== null) {
                return $linked;
            }
        }

        $email = strtolower(trim((string) $user->email));
        if ($email !== '') {
            $match = ManualDriver::query()
                ->whereRaw('LOWER(email) = ?', [$email])
                ->first();
            if ($match !== null) {
                return $match;
            }
        }

        $name = strtolower(trim((string) $user->name));
        if ($name === '') {
            return null;
        }

        return ManualDriver::query()
            ->whereRaw('LOWER(name) = ?', [$name])
            ->first();
    }

    private function formatDriverAccountProfile(ManualDriver $driver): array
    {
        return [
            'id' => (string) $driver->id,
            'driverId' => 'manual-'.$driver->id,
            'name' => $this->sanitizeText($driver->name, 'Driver'),
            'email' => $driver->email ?: null,
            'phone' => $driver->phone ?: null,
            'status' => $driver->status ?: 'available',
            'assignedVehicle' => $driver->assigned_vehicle_plate ?: null,
            'assignedVehicleGeotabId' => $driver->assigned_vehicle_geotab_id,
        ];
    }

    private function createOrLinkManualDriverAccount(ManualDriver $driver, Request $request, ?string $temporaryPassword = null): array
    {
        if (! Schema::hasColumn('manual_drivers', 'user_id')) {
            throw ValidationException::withMessages([
                'createLoginAccount' => 'Run the driver account linking migration before creating driver login accounts.',
            ]);
        }

        $actorRole = $this->actorManagedUserRole($request);
        if (! $this->managedUserCanManageRole($actorRole, 'driver')) {
            throw ValidationException::withMessages([
                'createLoginAccount' => 'Your role cannot create driver login accounts.',
            ]);
        }

        $email = strtolower(trim((string) $driver->email));
        if ($email === '' || ! filter_var($email, FILTER_VALIDATE_EMAIL)) {
            throw ValidationException::withMessages([
                'email' => 'A valid driver email is required before creating a login account.',
            ]);
        }

        $existingLinkedUser = $this->linkedUserForManualDriver($driver);
        if ($existingLinkedUser !== null) {
            $this->syncLinkedDriverAccount($driver);

            return [
                'loginAccountLinked' => true,
                'temporaryPasswordShownOnce' => false,
            ];
        }

        $user = User::query()->whereRaw('LOWER(email) = ?', [$email])->first();
        if ($user !== null) {
            if ($this->normalizeManagedUserRole($user->role ?? '') !== 'driver') {
                throw ValidationException::withMessages([
                    'email' => 'That email already belongs to a non-driver account.',
                ]);
            }
            $alreadyLinked = ManualDriver::query()
                ->where('user_id', $user->id)
                ->whereKeyNot($driver->id)
                ->exists();
            if ($alreadyLinked) {
                throw ValidationException::withMessages([
                    'email' => 'That driver account is already linked to another driver profile.',
                ]);
            }

            $driver->forceFill(['user_id' => $user->id])->save();
            $this->syncLinkedDriverAccount($driver->refresh());

            return [
                'loginAccountLinked' => true,
                'temporaryPasswordShownOnce' => false,
            ];
        }

        $password = $temporaryPassword ?: $this->generateTemporaryPassword();
        $actor = $this->sanitizeText($request->input('actor') ?: $actorRole, $actorRole);
        $user = User::query()->create([
            'name' => $this->sanitizeText($driver->name, 'Driver'),
            'email' => $email,
            'password' => Hash::make($password),
            'role' => 'driver',
            'phone' => trim((string) $driver->phone) ?: null,
            'status' => $this->manualDriverAccountStatus($driver),
            'must_change_password' => true,
            'created_by' => $actor,
            'activity_log' => [
                $this->managedUserActivity('created_from_driver_profile', $actor, [
                    'driverId' => (string) $driver->id,
                    'manualDriverName' => $driver->name,
                    'temporaryPasswordIssued' => true,
                ]),
            ],
        ]);

        $driver->forceFill(['user_id' => $user->id])->save();

        return [
            'loginAccountLinked' => true,
            'temporaryPassword' => $password,
            'temporaryPasswordShownOnce' => true,
        ];
    }

    private function linkedUserForManualDriver(ManualDriver $driver): ?User
    {
        if (! $this->managedUsersTableAvailable()) {
            return null;
        }

        if (Schema::hasColumn('manual_drivers', 'user_id') && $driver->user_id !== null) {
            $user = User::query()->find($driver->user_id);
            if ($user !== null) {
                return $user;
            }
        }

        $email = strtolower(trim((string) $driver->email));
        if ($email === '') {
            return null;
        }

        return User::query()
            ->where('role', 'driver')
            ->whereRaw('LOWER(email) = ?', [$email])
            ->first();
    }

    private function syncLinkedDriverAccount(ManualDriver $driver): void
    {
        $user = $this->linkedUserForManualDriver($driver);
        if ($user === null) {
            return;
        }

        $updates = [
            'name' => $this->sanitizeText($driver->name, 'Driver'),
            'phone' => trim((string) $driver->phone) ?: null,
            'status' => $this->manualDriverAccountStatus($driver),
        ];
        $email = strtolower(trim((string) $driver->email));
        if ($email !== '' && filter_var($email, FILTER_VALIDATE_EMAIL)) {
            $updates['email'] = $email;
        }

        $user->forceFill($updates)->save();
        if (Schema::hasColumn('manual_drivers', 'user_id') && $driver->user_id === null) {
            $driver->forceFill(['user_id' => $user->id])->save();
        }
    }

    private function manualDriverAccountStatus(ManualDriver $driver): string
    {
        $status = strtolower(trim((string) $driver->status));

        return in_array($status, ['inactive', 'deactivated'], true) ? 'inactive' : 'active';
    }

    private function actorManagedUserRole(Request $request): string
    {
        $authRole = $request->attributes->get('auth_role');
        if (is_string($authRole) && trim($authRole) !== '') {
            return $this->normalizeManagedUserRole($authRole);
        }

        return $this->normalizeManagedUserRole(
            $request->header('X-Pioneer-Role')
                ?: $request->input('actorRole')
                ?: $request->input('currentUserRole')
                ?: 'super_administrator'
        );
    }

    private function normalizeManagedUserRole(mixed $role): string
    {
        $normalized = Str::of((string) $role)
            ->lower()
            ->replace([' ', '-'], '_')
            ->trim()
            ->toString();

        return match ($normalized) {
            'super_admin', 'superadministrator', 'super_administrator' => 'super_administrator',
            'admin', 'administrator', 'system_admin', 'systemadministrator', 'system_administrator' => 'system_administrator',
            'fleet', 'manager', 'fleetmanager', 'fleet_manager' => 'fleet_manager',
            'dispatch', 'dispatcher' => 'dispatcher',
            'finance', 'accounting', 'accountingstaff', 'accounting_staff' => 'accounting_staff',
            'driver' => 'driver',
            default => array_key_exists($normalized, self::MANAGED_USER_ROLES) ? $normalized : 'driver',
        };
    }

    private function normalizeManagedUserStatus(mixed $status): string
    {
        $normalized = strtolower(trim((string) $status));

        return match ($normalized) {
            'inactive' => 'inactive',
            'locked' => 'locked',
            default => 'active',
        };
    }

    private function managedUserIsLocked(User $user): bool
    {
        if ($this->normalizeManagedUserStatus($user->status ?? 'active') === 'locked') {
            return true;
        }

        return $user->locked_until !== null && $user->locked_until->isFuture();
    }

    private function recordFailedLogin(?User $user, string $username, string $ip): void
    {
        $this->recordLoginAttempt($username, $user, $ip, false, 'invalid_credentials');

        $ipKey = $this->loginIpFailureKey($ip);
        $failures = (int) Cache::get($ipKey, 0) + 1;
        Cache::put($ipKey, $failures, now()->addMinutes(15));
        if ($failures >= 5) {
            Cache::put($this->loginIpLockKey($ip), true, now()->addMinutes(15));
        }

        if ($user === null) {
            return;
        }

        $count = (int) ($user->failed_login_count ?? 0) + 1;
        $updates = [
            'failed_login_count' => $count,
            'last_failed_login_at' => now(),
        ];

        if ($count >= 10) {
            $updates['status'] = 'locked';
            $updates['locked_until'] = null;
            $this->notifySuperAdministratorsOfAccountLock($user, $ip);
        }

        $user->forceFill($updates)->save();
    }

    private function recordLoginAttempt(string $username, ?User $user, string $ip, bool $successful, ?string $reason): void
    {
        if (! Schema::hasTable('login_attempt_logs')) {
            return;
        }

        LoginAttemptLog::query()->create([
            'email' => trim($username) !== '' ? strtolower(trim($username)) : null,
            'user_id' => $user?->id,
            'ip_address' => $ip,
            'successful' => $successful,
            'failure_reason' => $reason,
            'attempted_at' => now(),
        ]);

        Log::channel('auth_events')->info('pioneerpath.login_attempt', [
            'email' => $this->maskPersonalLogValue(trim($username) !== '' ? strtolower(trim($username)) : null),
            'userId' => $user?->id,
            'ip' => $ip,
            'successful' => $successful,
            'reason' => $reason,
        ]);
    }

    private function notifySuperAdministratorsOfAccountLock(User $user, string $ip): void
    {
        if (! $this->notificationHistoryTableAvailable()) {
            return;
        }

        NotificationHistory::query()->firstOrCreate(
            ['notification_id' => 'account-lock-'.$user->id],
            [
                'title' => 'Account locked after repeated sign-in failures',
                'message' => sprintf('%s was locked after 10 failed sign-in attempts. Last IP: %s.', $user->email, $ip),
                'category' => 'security',
                'status' => 'critical',
                'audience' => 'super_administrator',
                'payload' => [
                    'userId' => (string) $user->id,
                    'email' => (string) $user->email,
                    'ip' => $ip,
                    'url' => '/users',
                    'tag' => 'account-lock-'.$user->id,
                ],
                'delivered_at' => now(),
            ]
        );
    }

    private function loginIpFailureKey(string $ip): string
    {
        return 'pioneer_login_failures_ip_'.sha1($ip);
    }

    private function loginIpLockKey(string $ip): string
    {
        return 'pioneer_login_locked_ip_'.sha1($ip);
    }

    private function clearLoginIpFailures(string $ip): void
    {
        Cache::forget($this->loginIpFailureKey($ip));
        Cache::forget($this->loginIpLockKey($ip));
    }

    private function managedUserCanManageRole(string $actorRole, string $targetRole): bool
    {
        if ($actorRole === 'super_administrator') {
            return true;
        }

        return $actorRole === 'system_administrator'
            && in_array($targetRole, self::SYSTEM_ADMIN_CREATABLE_ROLES, true);
    }

    private function managedUserAppRole(string $role): string
    {
        return match ($role) {
            'super_administrator', 'system_administrator' => 'admin',
            'accounting_staff' => 'finance',
            'fleet_manager', 'dispatcher' => 'manager',
            default => 'driver',
        };
    }

    private function managedUserActivity(string $action, string $actor, array $meta = []): array
    {
        return [
            'action' => $action,
            'actor' => $this->sanitizeText($actor, 'system'),
            'timestamp' => now()->toIso8601String(),
            'meta' => $meta,
        ];
    }

    private function generateTemporaryPassword(): string
    {
        return 'Pioneer-'.Str::upper(Str::random(4)).'-'.random_int(1000, 9999);
    }

    private function requestWouldDeactivateManagedUser(array $validated, User $user): bool
    {
        if (! array_key_exists('status', $validated)) {
            return false;
        }

        return $this->normalizeManagedUserStatus($validated['status']) === 'inactive'
            && $this->normalizeManagedUserStatus($user->status ?? 'active') !== 'inactive';
    }

    private function managedDriverHasActiveTrip(User $user): bool
    {
        if ($this->normalizeManagedUserRole($user->role ?? '') !== 'driver') {
            return false;
        }

        $linkedDriver = $this->linkedManualDriverForUser($user);
        $driverKeys = array_filter([
            $linkedDriver !== null ? strtolower(trim((string) $linkedDriver->id)) : '',
            $linkedDriver !== null ? strtolower(trim('manual-'.$linkedDriver->id)) : '',
            $linkedDriver !== null ? strtolower(trim((string) $linkedDriver->name)) : '',
            $linkedDriver !== null ? strtolower(trim((string) $linkedDriver->email)) : '',
            strtolower(trim((string) $user->name)),
            strtolower(trim((string) $user->email)),
        ]);
        if ($driverKeys === []) {
            return false;
        }

        $activeStatuses = ['active', 'dispatched', 'in progress', 'in_progress', 'on trip', 'on_trip', 'pending_approval'];
        foreach ($this->assignmentGuardTrips() as $trip) {
            if (! is_array($trip)) {
                continue;
            }

            $status = strtolower(trim((string) ($trip['status'] ?? '')));
            if (! in_array($status, $activeStatuses, true)) {
                continue;
            }

            $tripDriverKeys = array_filter([
                strtolower(trim((string) ($trip['driver'] ?? ''))),
                strtolower(trim((string) ($trip['driverName'] ?? ''))),
                strtolower(trim((string) ($trip['assignedDriver'] ?? ''))),
                strtolower(trim((string) ($trip['driverId'] ?? ''))),
                strtolower(trim((string) ($trip['assignedDriverId'] ?? ''))),
            ]);
            if (array_intersect($driverKeys, $tripDriverKeys) !== []) {
                return true;
            }
        }

        return false;
    }

    private function managedUserHasAuditHistory(User $user): bool
    {
        if (is_array($user->activity_log) && $user->activity_log !== []) {
            return true;
        }

        $email = strtolower(trim((string) $user->email));
        $name = strtolower(trim((string) $user->name));

        foreach ($this->collectAuditLogEntries() as $entry) {
            if (($entry['entityType'] ?? '') === 'user' && (string) ($entry['entityId'] ?? '') === (string) $user->id) {
                return true;
            }

            $actorValues = array_map(
                static fn (mixed $value): string => strtolower(trim((string) $value)),
                [$entry['actor'] ?? '', $entry['actorEmail'] ?? '', $entry['actorName'] ?? '']
            );
            if (($email !== '' && in_array($email, $actorValues, true))
                || ($name !== '' && in_array($name, $actorValues, true))) {
                return true;
            }
        }

        return false;
    }

    private function manualDriverHasActiveTrip(ManualDriver $driver): bool
    {
        $driverKeys = array_filter([
            strtolower(trim((string) $driver->id)),
            strtolower(trim('manual-'.$driver->id)),
            strtolower(trim((string) $driver->name)),
            strtolower(trim((string) $driver->email)),
        ]);
        if ($driverKeys === []) {
            return false;
        }

        $activeStatuses = ['active', 'dispatched', 'in progress', 'in_progress', 'on trip', 'on_trip', 'pending_approval'];
        foreach ($this->assignmentGuardTrips() as $trip) {
            if (! is_array($trip)) {
                continue;
            }

            $status = strtolower(trim((string) ($trip['status'] ?? '')));
            if (! in_array($status, $activeStatuses, true)) {
                continue;
            }

            $tripDriverKeys = array_filter([
                strtolower(trim((string) ($trip['driver'] ?? ''))),
                strtolower(trim((string) ($trip['driverName'] ?? ''))),
                strtolower(trim((string) ($trip['assignedDriver'] ?? ''))),
                strtolower(trim((string) ($trip['driverId'] ?? ''))),
                strtolower(trim((string) ($trip['assignedDriverId'] ?? ''))),
            ]);
            if (array_intersect($driverKeys, $tripDriverKeys) !== []) {
                return true;
            }
        }

        return false;
    }

    private function assignmentGuardTrips(): array
    {
        $snapshot = $this->snapshot();
        $trips = is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [];
        $workflow = $this->workflowState();
        $customTrips = is_array($workflow['customTrips'] ?? null) ? $workflow['customTrips'] : [];

        foreach ($customTrips as $trip) {
            if (is_array($trip)) {
                $trips[] = $trip;
            }
        }

        $deduped = [];
        foreach ($trips as $index => $trip) {
            if (! is_array($trip)) {
                continue;
            }

            $tripId = trim((string) ($trip['tripId'] ?? $trip['id'] ?? ''));
            $key = $tripId !== '' ? $tripId : 'assignment-trip-'.$index;
            $deduped[$key] = $trip;
        }

        return array_values($deduped);
    }

    private function manualDriverHasTripHistory(ManualDriver $driver): bool
    {
        $driverKeys = array_filter([
            strtolower(trim((string) $driver->id)),
            strtolower(trim('manual-'.$driver->id)),
            strtolower(trim((string) $driver->name)),
            strtolower(trim((string) $driver->email)),
        ]);
        if ($driverKeys === []) {
            return false;
        }

        foreach (($this->snapshot()['trips'] ?? []) as $trip) {
            if (! is_array($trip)) {
                continue;
            }

            $tripDriverKeys = array_filter([
                strtolower(trim((string) ($trip['driver'] ?? ''))),
                strtolower(trim((string) ($trip['driverName'] ?? ''))),
                strtolower(trim((string) ($trip['assignedDriver'] ?? ''))),
                strtolower(trim((string) ($trip['driverId'] ?? ''))),
                strtolower(trim((string) ($trip['assignedDriverId'] ?? ''))),
            ]);
            if (array_intersect($driverKeys, $tripDriverKeys) !== []) {
                return true;
            }
        }

        return false;
    }

    private function loadManualDrivers(mixed $status = null): array
    {
        if (! $this->manualDriversTableAvailable()) {
            return [];
        }

        $query = ManualDriver::query()->orderBy('name');
        $status = strtolower(trim((string) ($status ?? 'all')));
        if ($status !== '' && $status !== 'all') {
            if (in_array($status, ['active', 'assignable'], true)) {
                $query->whereRaw('LOWER(status) NOT IN (?, ?)', ['inactive', 'deactivated']);
            } else {
                $query->whereRaw('LOWER(status) = ?', [$status]);
            }
        }

        $drivers = $query->get();
        $syncStates = $this->manualDriverSyncStates($drivers->pluck('id')->map(fn ($id): string => (string) $id)->all());
        foreach ($drivers as $driver) {
            $driverId = (string) $driver->id;
            if (($driver->sync_status ?? null) === 'local_modified') {
                $syncStates[$driverId] = $this->driverGeotabSyncState($driver);

                continue;
            }
            if (isset($syncStates[$driverId])) {
                continue;
            }
            $meta = is_array($driver->meta) ? $driver->meta : [];
            $geotabUserId = trim((string) data_get($meta, 'geotabUserId', ''));
            $syncStates[$driverId] = $geotabUserId !== ''
                ? [
                    'status' => 'synced',
                    'label' => 'GeoTab: Up to date',
                    'color' => 'green',
                    'geotabUserId' => $geotabUserId,
                    'pendingWriteJobId' => null,
                    'syncError' => null,
                ]
                : [
                    'status' => 'not_synced',
                    'label' => 'GeoTab: Never synced',
                    'color' => 'gray',
                    'geotabUserId' => null,
                    'pendingWriteJobId' => null,
                    'syncError' => data_get($meta, 'syncError'),
                ];
        }

        return array_values(array_map(
            fn (ManualDriver $driver): array => $this->formatManualDriver($driver, [
                'syncStates' => $syncStates,
            ]),
            $drivers->all(),
        ));
    }

    private function formatManualDriver(ManualDriver $driver, array $context = []): array
    {
        $syncStates = is_array($context['syncStates'] ?? null) ? $context['syncStates'] : [];
        $syncState = $syncStates[(string) $driver->id] ?? $this->driverGeotabSyncState($driver);
        $linkedUser = $this->linkedUserForManualDriver($driver);
        $userAccount = $linkedUser !== null ? [
            'id' => (string) $linkedUser->id,
            'fullName' => $this->sanitizeText($linkedUser->name, 'Driver'),
            'email' => (string) $linkedUser->email,
            'status' => $this->normalizeManagedUserStatus($linkedUser->status ?? 'active'),
            'mustChangePassword' => (bool) ($linkedUser->must_change_password ?? false),
            'lastLoginAt' => $linkedUser->last_login_at?->toIso8601String(),
        ] : null;

        return [
            'id' => (string) $driver->id,
            'source' => 'manual',
            'name' => $driver->name,
            'driverId' => 'manual-'.$driver->id,
            'license' => $driver->license ?: 'N/A',
            'licenseExpiry' => (string) data_get($driver->meta, 'licenseExpiry', 'N/A'),
            'phone' => $driver->phone ?: 'N/A',
            'email' => $driver->email ?: 'N/A',
            'address' => $this->sanitizeText(data_get($driver->meta, 'address'), 'N/A'),
            'emergencyContact' => $this->sanitizeText(data_get($driver->meta, 'emergencyContact'), 'N/A'),
            'joinDate' => $this->displayShortDate($driver->created_at),
            'status' => $driver->status ?: 'available',
            'trips' => (int) data_get($driver->meta, 'trips', 0),
            'revenue' => $this->money((float) data_get($driver->meta, 'revenue', 0)),
            'score' => (int) data_get($driver->meta, 'score', 92),
            'delays' => (int) data_get($driver->meta, 'delays', 0),
            'assignedVehicle' => $driver->assigned_vehicle_plate ?: 'N/A',
            'assignedVehicleGeotabId' => $driver->assigned_vehicle_geotab_id,
            'employeeNumber' => (string) data_get($driver->meta, 'employeeNumber', ''),
            'hosRuleSet' => (string) data_get($driver->meta, 'hosRuleSet', 'N/A'),
            'userId' => $linkedUser !== null ? (string) $linkedUser->id : null,
            'hasLoginAccount' => $linkedUser !== null,
            'canCreateLoginAccount' => $linkedUser === null
                && filter_var(strtolower(trim((string) $driver->email)), FILTER_VALIDATE_EMAIL) !== false,
            'userAccount' => $userAccount,
            'syncStatus' => $syncState['status'],
            'syncLabel' => $syncState['label'],
            'syncBadgeColor' => $syncState['color'],
            'hasLocalGeotabChanges' => $syncState['status'] === 'local_modified',
            'canPushToGeotab' => $syncState['status'] === 'local_modified',
            'geotabUserId' => $syncState['geotabUserId'],
            'geotabId' => $syncState['geotabUserId'],
            'pendingWriteJobId' => $syncState['pendingWriteJobId'],
            'syncError' => $syncState['syncError'],
            'geotabSnapshot' => $driver->geotab_snapshot ?? data_get($driver->meta, 'geotabSnapshot'),
        ];
    }

    private function driverGeotabSyncState(ManualDriver $driver): array
    {
        $meta = is_array($driver->meta) ? $driver->meta : [];
        $columnStatus = trim((string) ($driver->sync_status ?? ''));
        if ($columnStatus === 'local_modified') {
            return [
                'status' => 'local_modified',
                'label' => 'GeoTab: Local changes pending',
                'color' => 'blue',
                'geotabUserId' => data_get($meta, 'geotabUserId'),
                'pendingWriteJobId' => null,
                'syncError' => null,
            ];
        }
        if ($columnStatus === 'pending_approval') {
            return [
                'status' => 'pending_approval',
                'label' => 'GeoTab: Push awaiting approval',
                'color' => 'amber',
                'geotabUserId' => data_get($meta, 'geotabUserId'),
                'pendingWriteJobId' => $driver->pending_write_job_id !== null ? (string) $driver->pending_write_job_id : data_get($meta, 'pendingWriteJobId'),
                'syncError' => $driver->sync_error ?? data_get($meta, 'syncError'),
            ];
        }
        if (in_array($columnStatus, ['failed', 'rejected', 'permanently_failed'], true)) {
            return [
                'status' => $columnStatus,
                'label' => $columnStatus === 'permanently_failed' ? 'GeoTab: Permanently failed' : 'GeoTab: Sync failed',
                'color' => 'red',
                'geotabUserId' => data_get($meta, 'geotabUserId'),
                'pendingWriteJobId' => $driver->pending_write_job_id !== null ? (string) $driver->pending_write_job_id : data_get($meta, 'pendingWriteJobId'),
                'syncError' => $driver->sync_error ?? data_get($meta, 'syncError'),
            ];
        }
        $latestJob = null;
        if ($this->writeBack->tableAvailable()) {
            $latestJob = GeotabWriteJob::query()
                ->where('local_type', 'manual_driver')
                ->where('local_id', (string) $driver->id)
                ->latest('updated_at')
                ->latest('id')
                ->first();
        }

        if ($latestJob?->status === 'succeeded') {
            $geotabUserId = (string) ($latestJob->geotab_id ?: data_get($meta, 'geotabUserId', ''));

            return [
                'status' => 'synced',
                'label' => 'GeoTab: Up to date',
                'color' => 'green',
                'geotabUserId' => $geotabUserId,
                'pendingWriteJobId' => null,
                'syncError' => null,
            ];
        }

        if ($latestJob !== null) {
            return [
                'status' => 'pending_approval',
                'label' => 'GeoTab: Push awaiting approval',
                'color' => 'amber',
                'geotabUserId' => data_get($meta, 'geotabUserId'),
                'pendingWriteJobId' => (string) $latestJob->id,
                'syncError' => $latestJob->last_error,
            ];
        }

        if (trim((string) data_get($meta, 'geotabUserId', '')) !== '') {
            return [
                'status' => 'synced',
                'label' => 'Synced',
                'color' => 'green',
                'geotabUserId' => data_get($meta, 'geotabUserId'),
                'pendingWriteJobId' => null,
                'syncError' => null,
            ];
        }

        return [
            'status' => $columnStatus !== '' ? $columnStatus : 'not_synced',
            'label' => $columnStatus === 'not_staged' ? 'Not Synced' : 'Not Synced',
            'color' => 'gray',
            'geotabUserId' => null,
            'pendingWriteJobId' => null,
            'syncError' => $driver->sync_error ?? data_get($meta, 'syncError'),
        ];
    }

    /**
     * @param  array<int, string>  $driverIds
     * @return array<string, array<string, mixed>>
     */
    private function manualDriverSyncStates(array $driverIds): array
    {
        $driverIds = array_values(array_unique(array_filter($driverIds, fn (string $id): bool => $id !== '')));
        if ($driverIds === [] || ! $this->writeBack->tableAvailable()) {
            return [];
        }

        $latestJobs = [];
        GeotabWriteJob::query()
            ->where('local_type', 'manual_driver')
            ->whereIn('local_id', $driverIds)
            ->orderByDesc('updated_at')
            ->orderByDesc('id')
            ->get()
            ->each(function (GeotabWriteJob $job) use (&$latestJobs): void {
                $localId = (string) $job->local_id;
                $latestJobs[$localId] ??= $job;
            });

        $states = [];
        foreach ($driverIds as $driverId) {
            $job = $latestJobs[$driverId] ?? null;
            if ($job?->status === 'succeeded') {
                $states[$driverId] = [
                    'status' => 'synced',
                    'label' => 'GeoTab: Up to date',
                    'color' => 'green',
                    'geotabUserId' => (string) $job->geotab_id,
                    'pendingWriteJobId' => null,
                    'syncError' => null,
                ];

                continue;
            }

            if ($job?->status === 'rejected') {
                $states[$driverId] = [
                    'status' => 'local_modified',
                    'label' => 'GeoTab: Local changes pending',
                    'color' => 'blue',
                    'geotabUserId' => null,
                    'pendingWriteJobId' => null,
                    'syncError' => $job->last_error,
                ];

                continue;
            }

            if ($job !== null) {
                $states[$driverId] = [
                    'status' => $this->syncStatusFromWriteBackJob($job),
                    'label' => $this->geotabSyncLabel($this->syncStatusFromWriteBackJob($job)),
                    'color' => 'amber',
                    'geotabUserId' => null,
                    'pendingWriteJobId' => (string) $job->id,
                    'syncError' => $job->last_error,
                ];
            }
        }

        return $states;
    }

    private function formatWriteBackJob(GeotabWriteJob $job): array
    {
        $payload = is_array($job->payload) ? $job->payload : [];
        $summary = $this->writeBackPayloadSummary($payload);
        $previewPayload = is_array($job->preview_payload)
            ? $job->preview_payload
            : $this->buildGeotabPreviewPayload((string) $job->entity_type, (string) ($summary['name'] ?? $job->entity_type), $payload, null);

        return [
            'id' => (string) $job->id,
            'action' => $job->action,
            'entityType' => $job->entity_type,
            'localType' => $job->local_type,
            'localId' => $job->local_id,
            'geotabId' => $job->geotab_id,
            'status' => $job->status,
            'attempts' => (int) $job->attempts,
            'maxAttempts' => (int) $job->max_attempts,
            'nextAttemptAt' => $job->next_attempt_at?->toIso8601String(),
            'lastAttemptAt' => $job->last_attempt_at?->toIso8601String(),
            'permanentlyFailedAt' => $job->permanently_failed_at?->toIso8601String(),
            'idempotencyKey' => $job->idempotency_key,
            'createdBy' => $job->created_by,
            'approvedBy' => $job->approved_by,
            'approvedAt' => $job->approved_at?->toIso8601String(),
            'processedAt' => $job->processed_at?->toIso8601String(),
            'createdAt' => $job->created_at?->toIso8601String(),
            'updatedAt' => $job->updated_at?->toIso8601String(),
            'lastError' => $job->last_error,
            'payload' => $payload,
            'previewPayload' => $previewPayload,
            'payloadSummary' => $summary,
            'requiresTemporaryPassword' => $this->writeBackJobRequiresTemporaryPassword($job),
            'requiresGeotabCompanyGroup' => $this->writeBackPayloadUsesZone($payload),
            'geotabCompanyGroupConfigured' => $this->configuredGeotabCompanyGroupId() !== '',
            'result' => $job->result,
            'auditTrail' => is_array($job->audit_trail) ? $job->audit_trail : [],
        ];
    }

    private function writeBackPayloadUsesZone(array $payload): bool
    {
        if (is_array($payload['zone'] ?? null)) {
            return true;
        }

        return collect((array) data_get($payload, 'operations', []))
            ->contains(fn ($operation): bool => is_array($operation)
                && str_starts_with((string) ($operation['action'] ?? ''), 'zone.'));
    }

    private function writeBackJobRequiresTemporaryPassword(GeotabWriteJob $job): bool
    {
        if ($job->action === 'driver.create') {
            return true;
        }

        return collect((array) data_get($job->payload, 'operations', []))
            ->contains(fn ($operation): bool => is_array($operation) && ($operation['action'] ?? null) === 'driver.create');
    }

    private function writeBackPayloadSummary(array $payload): array
    {
        if (is_array($payload['assignment'] ?? null)) {
            return array_filter([
                'name' => trim((string) data_get($payload, 'assignment.driverName').' + '.(string) data_get($payload, 'assignment.vehiclePlate')),
                'operationCount' => is_array($payload['operations'] ?? null) ? count($payload['operations']) : null,
                'groupType' => (string) ($payload['groupType'] ?? ''),
            ], fn ($value): bool => $value !== '' && $value !== null);
        }

        $entity = data_get($payload, 'entity', []);
        $route = data_get($payload, 'route', []);

        return array_filter([
            'name' => (string) (data_get($entity, 'name') ?: data_get($route, 'name') ?: ''),
            'userName' => (string) data_get($entity, 'userName', ''),
            'deviceId' => (string) (data_get($payload, 'deviceId') ?: data_get($route, 'device.id') ?: ''),
            'routeId' => (string) data_get($payload, 'routeId', ''),
            'stopCount' => is_array(data_get($payload, 'planItems')) ? count(data_get($payload, 'planItems')) : null,
        ], fn ($value): bool => $value !== '' && $value !== null);
    }

    private function queueDriverGeotabSync(ManualDriver $driver, string $action, string $createdBy = 'system'): void
    {
        if (! $this->writeBack->tableAvailable()) {
            return;
        }

        $meta = is_array($driver->meta) ? $driver->meta : [];
        $geotabUserId = trim((string) data_get($meta, 'geotabUserId', ''));
        $normalizedAction = match ($action) {
            'create' => $geotabUserId === '' ? 'driver.create' : 'driver.update',
            'update' => $geotabUserId === '' ? 'driver.create' : 'driver.update',
            'deactivate' => $geotabUserId === '' ? null : 'driver.deactivate',
            default => null,
        };

        if ($normalizedAction === null) {
            return;
        }

        $payload = $this->driverWriteBackPayload($driver, $normalizedAction, $geotabUserId);
        $grouped = $this->driverVehicleAssignmentWriteBackPayload($driver, $normalizedAction, $payload);
        if ($grouped !== null) {
            $job = $this->writeBack->createJob(
                'group.driver_vehicle_assignment',
                'Driver + Vehicle Assignment',
                $grouped['payload'],
                'grouped_writeback',
                (string) $driver->id,
                'driver-vehicle-assignment:'.$driver->id.':'.$normalizedAction.':'.($driver->updated_at?->timestamp ?? time()),
                $createdBy,
                $grouped['previewPayload'],
            );

            if ($job === null) {
                return;
            }

            $driver->forceFill([
                'sync_status' => 'pending_approval',
                'sync_error' => null,
                'pending_write_job_id' => $job->id,
                'meta' => [
                    ...$meta,
                    'syncStatus' => 'pending_approval',
                    'syncAction' => 'group.driver_vehicle_assignment',
                    'syncQueuedAt' => now()->toIso8601String(),
                    'pendingWriteJobId' => (string) $job->id,
                    'syncError' => null,
                ],
            ])->saveQuietly();
            $grouped['vehicle']->forceFill([
                'sync_status' => 'pending_approval',
                'sync_error' => null,
                'pending_write_job_id' => $job->id,
            ])->saveQuietly();

            Log::channel('write_back')->info('PioneerPath staged grouped GeoTab driver/vehicle assignment write-back', [
                'driverId' => $driver->id,
                'vehicleId' => $grouped['vehicle']->id,
                'jobId' => $job->id,
                'driverAction' => $normalizedAction,
            ]);

            return;
        }

        $job = $this->writeBack->createJob(
            $normalizedAction,
            'User',
            $payload,
            'manual_driver',
            (string) $driver->id,
            'manual-driver:'.$driver->id.':'.$normalizedAction.':'.($driver->updated_at?->timestamp ?? time()),
            $createdBy,
            $this->buildGeotabPreviewPayload('Driver', (string) $driver->name, $payload, $driver->geotab_snapshot ?? data_get($meta, 'geotabSnapshot')),
        );

        if ($job === null) {
            return;
        }

        $driver->forceFill([
            'sync_status' => 'pending_approval',
            'sync_error' => null,
            'pending_write_job_id' => $job->id,
            'meta' => [
                ...$meta,
                'syncStatus' => 'pending_approval',
                'syncAction' => $normalizedAction,
                'syncQueuedAt' => now()->toIso8601String(),
                'pendingWriteJobId' => (string) $job->id,
                'syncError' => null,
            ],
        ])->saveQuietly();

        Log::channel('write_back')->info('PioneerPath staged GeoTab driver write-back for admin approval', [
            'driverId' => $driver->id,
            'jobId' => $job->id,
            'action' => $normalizedAction,
        ]);
    }

    private function markManualDriverGeotabDirty(ManualDriver $driver): void
    {
        $meta = is_array($driver->meta) ? $driver->meta : [];
        $action = $this->manualDriverWriteBackAction($driver);
        if ($action === null) {
            $driver->forceFill([
                'sync_status' => 'not_staged',
                'sync_error' => null,
                'pending_write_job_id' => null,
                'meta' => [
                    ...$meta,
                    'syncStatus' => 'not_staged',
                    'syncError' => null,
                    'pendingWriteJobId' => null,
                ],
            ])->saveQuietly();

            return;
        }

        $payload = $this->driverWriteBackPayload($driver, $action, trim((string) data_get($meta, 'geotabUserId', '')));
        $status = $this->payloadMatchesGeotabSnapshot($payload, $driver->geotab_snapshot ?? data_get($meta, 'geotabSnapshot'))
            ? 'synced'
            : 'local_modified';
        $driver->forceFill([
            'sync_status' => $status,
            'sync_error' => null,
            'pending_write_job_id' => null,
            'meta' => [
                ...$meta,
                'syncStatus' => $status,
                'syncError' => null,
                'pendingWriteJobId' => null,
            ],
        ])->saveQuietly();
    }

    private function manualDriverWriteBackAction(ManualDriver $driver): ?string
    {
        $meta = is_array($driver->meta) ? $driver->meta : [];
        $geotabUserId = trim((string) data_get($meta, 'geotabUserId', ''));
        $inactive = in_array(strtolower((string) $driver->status), ['inactive', 'deactivated'], true);
        if ($inactive) {
            return $geotabUserId === '' ? null : 'driver.deactivate';
        }

        return $geotabUserId === '' ? 'driver.create' : 'driver.update';
    }

    public function pushManualDriverToGeotab(Request $request, string $driverId): JsonResponse
    {
        if (! $this->manualDriversTableAvailable()) {
            return $this->respondError('Manual drivers table is not available.', 503);
        }

        $driver = ManualDriver::query()->find($driverId);
        if ($driver === null) {
            return $this->respondError('Manual driver not found.', 404);
        }

        $action = $this->manualDriverWriteBackAction($driver);
        if ($action === null) {
            return $this->respondError('This local driver has no GeoTab user to deactivate.', 422);
        }
        $meta = is_array($driver->meta) ? $driver->meta : [];
        $payload = $this->driverWriteBackPayload($driver, $action, trim((string) data_get($meta, 'geotabUserId', '')));
        $previewPayload = $this->buildGeotabPreviewPayload('Driver', (string) $driver->name, $payload, $driver->geotab_snapshot ?? data_get($meta, 'geotabSnapshot'));
        $grouped = $this->driverVehicleAssignmentWriteBackPayload($driver, $action, $payload);
        if ($grouped !== null) {
            $payload = $grouped['payload'];
            $previewPayload = $grouped['previewPayload'];
        }

        if ($this->payloadMatchesGeotabSnapshot($payload, $driver->geotab_snapshot ?? data_get($meta, 'geotabSnapshot'))) {
            return $this->respondData([
                ...$this->formatManualDriver($driver),
                'geotabAlreadyUpToDate' => true,
                'message' => 'GeoTab is already up to date.',
            ]);
        }
        if ($this->isGeotabPreviewRequest($request)) {
            return $this->respondData([
                ...$this->formatManualDriver($driver),
                ...$this->pendingGeotabPushMetadata('manual_driver', (string) $driver->id),
                'message' => 'Review this GeoTab payload before staging it for approval.',
                'previewOnly' => true,
                'preview' => $payload,
                'previewPayload' => $previewPayload,
            ]);
        }

        $this->queueDriverGeotabSync($driver, str_contains($action, 'deactivate') ? 'deactivate' : 'update', $this->geotabActorFromRequest($request));
        $this->clearFleetCaches();

        return $this->respondData([
            ...$this->formatManualDriver($driver->refresh()),
            'message' => 'GeoTab push request staged for admin approval.',
            'preview' => $payload,
        ]);
    }

    private function isGeotabPreviewRequest(Request $request): bool
    {
        return $request->boolean('previewOnly') || $request->boolean('preview_only');
    }

    private function geotabActorFromRequest(Request $request): string
    {
        $user = $request->attributes->get('auth_user');
        $name = trim((string) ($user?->name ?? ''));
        $email = trim((string) ($user?->email ?? ''));
        $id = trim((string) ($request->attributes->get('auth_user_id') ?? ''));

        return $email !== '' ? $email : ($name !== '' ? $name : ($id !== '' ? 'user:'.$id : 'system'));
    }

    /**
     * @return array<string, mixed>
     */
    private function pendingGeotabPushMetadata(string $localType, string $localId): array
    {
        $job = $this->pendingGeotabWriteBackFor($localType, $localId);
        if ($job === null) {
            return [
                'hasPendingGeotabPush' => false,
                'pendingGeotabPush' => null,
            ];
        }

        return [
            'hasPendingGeotabPush' => true,
            'pendingGeotabPush' => [
                'id' => (string) $job->id,
                'status' => (string) $job->status,
                'action' => (string) $job->action,
                'createdBy' => $job->created_by,
                'createdAt' => $job->created_at?->toIso8601String(),
                'approvedAt' => $job->approved_at?->toIso8601String(),
            ],
        ];
    }

    private function pendingGeotabWriteBackFor(string $localType, string $localId): ?GeotabWriteJob
    {
        if (! $this->writeBack->tableAvailable()) {
            return null;
        }

        $statuses = ['pending_approval', 'approved'];
        $direct = GeotabWriteJob::query()
            ->whereIn('status', $statuses)
            ->where('local_type', $localType)
            ->where('local_id', $localId)
            ->latest('updated_at')
            ->latest('id')
            ->first();
        if ($direct !== null) {
            return $direct;
        }

        return GeotabWriteJob::query()
            ->whereIn('status', $statuses)
            ->where('local_type', 'grouped_writeback')
            ->latest('updated_at')
            ->latest('id')
            ->limit(100)
            ->get()
            ->first(function (GeotabWriteJob $job) use ($localType, $localId): bool {
                $operations = data_get($job->payload, 'operations', []);
                if (! is_array($operations)) {
                    return false;
                }

                foreach ($operations as $operation) {
                    if ((string) data_get($operation, 'localType') === $localType
                        && (string) data_get($operation, 'localId') === $localId) {
                        return true;
                    }
                }

                return false;
            });
    }

    private function buildGeotabPreviewPayload(string $entityType, string $entityName, array $payload, mixed $snapshot): array
    {
        $snapshotMap = is_array($snapshot) ? $snapshot : [];
        $before = $this->flattenGeotabPreviewValues($snapshotMap);
        $after = $this->flattenGeotabPreviewValues($payload);
        $isFirstPush = $snapshotMap === [];
        $rows = [];

        foreach ($after as $field => $newValue) {
            $oldValue = $before[$field] ?? '';
            if ($isFirstPush || $oldValue !== $newValue) {
                $rows[] = [
                    'field' => $field,
                    'before' => $isFirstPush ? 'Not in GeoTab' : $oldValue,
                    'after' => $newValue,
                ];
            }
        }

        usort($rows, fn (array $a, array $b): int => strcmp((string) $a['field'], (string) $b['field']));

        return [
            'entityType' => $entityType,
            'entityName' => $entityName !== '' ? $entityName : $entityType,
            'isFirstPush' => $isFirstPush,
            'rows' => $rows,
            'payload' => $payload,
            'snapshot' => $snapshotMap,
        ];
    }

    private function buildGroupedGeotabPreviewPayload(string $entityName, array $payload, array $groups): array
    {
        return [
            'entityType' => 'Grouped GeoTab Push',
            'entityName' => $entityName,
            'isGrouped' => true,
            'groups' => $groups,
            'payload' => $payload,
            'snapshot' => [],
            'rows' => [],
            'isFirstPush' => collect($groups)->contains(fn (array $group): bool => (bool) ($group['isFirstPush'] ?? false)),
        ];
    }

    private function driverVehicleAssignmentWriteBackPayload(ManualDriver $driver, string $driverAction, array $driverPayload): ?array
    {
        if ($driverAction === 'driver.deactivate' || ! Schema::hasTable('manual_vehicles')) {
            return null;
        }

        $plate = trim((string) $driver->assigned_vehicle_plate);
        if ($plate === '') {
            return null;
        }

        $vehicle = ManualVehicle::query()
            ->where('plate_number', $plate)
            ->whereNotNull('geotab_device_id')
            ->where('geotab_device_id', '!=', '')
            ->first();
        if ($vehicle === null) {
            return null;
        }

        $vehiclePayload = $this->manualVehicleWriteBackPayload($vehicle);
        $driverSnapshot = $driver->geotab_snapshot ?? data_get(is_array($driver->meta) ? $driver->meta : [], 'geotabSnapshot');
        $vehicleSnapshot = $vehicle->geotab_snapshot ?? null;
        $driverPreview = $this->buildGeotabPreviewPayload('Driver', (string) $driver->name, $driverPayload, $driverSnapshot);
        $vehiclePreview = $this->buildGeotabPreviewPayload('Vehicle', (string) $vehicle->plate_number, $vehiclePayload, $vehicleSnapshot);
        $payload = [
            'groupType' => 'driver_vehicle_assignment',
            'operations' => [
                [
                    'action' => $driverAction,
                    'entityType' => 'User',
                    'entityName' => (string) $driver->name,
                    'localType' => 'manual_driver',
                    'localId' => (string) $driver->id,
                    'payload' => $driverPayload,
                    'snapshot' => is_array($driverSnapshot) ? $driverSnapshot : [],
                ],
                [
                    'action' => 'vehicle.update_device',
                    'entityType' => 'Device',
                    'entityName' => (string) $vehicle->plate_number,
                    'localType' => 'manual_vehicle',
                    'localId' => (string) $vehicle->id,
                    'payload' => $vehiclePayload,
                    'snapshot' => is_array($vehicleSnapshot) ? $vehicleSnapshot : [],
                ],
            ],
            'assignment' => [
                'driverName' => (string) $driver->name,
                'vehiclePlate' => (string) $vehicle->plate_number,
            ],
        ];

        return [
            'payload' => $payload,
            'vehicle' => $vehicle,
            'previewPayload' => $this->buildGroupedGeotabPreviewPayload(
                trim((string) $driver->name).' + '.trim((string) $vehicle->plate_number),
                $payload,
                [$driverPreview, $vehiclePreview],
            ),
        ];
    }

    /**
     * @return array<string, string>
     */
    private function flattenGeotabPreviewValues(mixed $value, string $prefix = ''): array
    {
        $rows = [];
        if (is_array($value)) {
            foreach ($value as $key => $item) {
                $part = is_int($key) ? '['.$key.']' : (string) $key;
                $next = $prefix === ''
                    ? $part
                    : (is_int($key) ? $prefix.$part : $prefix.'.'.$part);
                $rows += $this->flattenGeotabPreviewValues($item, $next);
            }

            return $rows;
        }

        if ($prefix !== '') {
            $rows[$prefix] = $this->displayGeotabPreviewValue($value);
        }

        return $rows;
    }

    private function displayGeotabPreviewValue(mixed $value): string
    {
        if ($value === null || (is_string($value) && trim($value) === '')) {
            return 'N/A';
        }

        if (is_bool($value)) {
            return $value ? 'true' : 'false';
        }

        if (is_scalar($value)) {
            return (string) $value;
        }

        return (string) json_encode($value);
    }

    private function driverWriteBackPayload(ManualDriver $driver, string $action, string $geotabUserId = ''): array
    {
        $name = trim((string) $driver->name);
        [$firstName, $lastName] = $this->splitDriverName($name);
        $email = trim((string) $driver->email);
        $userName = $email !== '' ? $email : 'driver-'.$driver->id.'@pioneerpath.local';

        $entity = array_filter([
            'id' => $geotabUserId !== '' ? $geotabUserId : null,
            'name' => $name,
            'firstName' => $firstName,
            'lastName' => $lastName,
            'userName' => $userName,
            'email' => $email !== '' ? $email : null,
            'phoneNumber' => trim((string) $driver->phone) !== '' ? trim((string) $driver->phone) : null,
            'licenseNumber' => trim((string) $driver->license) !== '' ? trim((string) $driver->license) : null,
            'isDriver' => true,
        ], fn ($value): bool => $value !== null && $value !== '');

        if ($action === 'driver.create') {
            $entity['activeFrom'] = now()->utc()->toIso8601String();
        }

        return ['entity' => $entity];
    }

    private function splitDriverName(string $name): array
    {
        $parts = preg_split('/\s+/', trim($name)) ?: [];
        if (count($parts) <= 1) {
            return [$name, ''];
        }

        $first = array_shift($parts);

        return [(string) $first, implode(' ', $parts)];
    }

    private function payloadMatchesGeotabSnapshot(array $payload, mixed $snapshot): bool
    {
        if ($payload === [] || $snapshot === null || $snapshot === '') {
            return false;
        }

        if (is_string($snapshot)) {
            $decoded = json_decode($snapshot, true);
            $snapshot = is_array($decoded) ? $decoded : null;
        }
        if (! is_array($snapshot)) {
            return false;
        }

        return $this->canonicalPayloadHash($payload) === $this->canonicalPayloadHash($snapshot);
    }

    private function canonicalPayloadHash(array $payload): string
    {
        $normalized = $this->sortPayloadRecursively($payload);

        return sha1(json_encode($normalized, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    }

    private function sortPayloadRecursively(array $payload): array
    {
        foreach ($payload as $key => $value) {
            if (is_array($value)) {
                $payload[$key] = $this->sortPayloadRecursively($value);
            }
        }
        if (! array_is_list($payload)) {
            ksort($payload);
        }

        return $payload;
    }

    private function geotabSyncLabel(mixed $status): string
    {
        return match (trim((string) $status)) {
            'synced' => 'GeoTab: Up to date',
            'pending_approval' => 'GeoTab: Push awaiting approval',
            'approved', 'processing' => 'GeoTab: Push approved, executing',
            'local_modified' => 'GeoTab: Local changes pending',
            'failed', 'rejected' => 'GeoTab: Sync failed',
            'permanently_failed' => 'GeoTab: Permanently failed',
            'removed' => 'Removed from GeoTab',
            default => 'GeoTab: Never synced',
        };
    }

    private function syncStatusFromWriteBackJob(GeotabWriteJob $job): string
    {
        return match ((string) $job->status) {
            'succeeded' => 'synced',
            'approved', 'processing' => 'processing',
            'failed', 'rejected' => 'failed',
            'permanently_failed' => 'permanently_failed',
            default => (string) $job->status,
        };
    }

    private function mergeManualDrivers(array $driversView): array
    {
        $manualDrivers = $this->loadManualDrivers();
        if ($manualDrivers === []) {
            return $driversView;
        }

        $byName = [];
        foreach ($driversView as $index => $driver) {
            $name = strtolower(trim((string) ($driver['name'] ?? '')));
            if ($name !== '') {
                $byName[$name] = $index;
            }
        }

        foreach ($manualDrivers as $manualDriver) {
            $name = strtolower(trim((string) ($manualDriver['name'] ?? '')));
            if ($name !== '' && array_key_exists($name, $byName)) {
                $driversView[$byName[$name]] = [
                    ...$driversView[$byName[$name]],
                    ...$manualDriver,
                ];

                continue;
            }

            $driversView[] = $manualDriver;
        }

        return $driversView;
    }

    private function loadManualVehicles(mixed $status = null): array
    {
        if (! $this->manualVehiclesTableAvailable()) {
            return [];
        }

        $query = ManualVehicle::query()->orderBy('plate_number');
        $status = strtolower(trim((string) ($status ?? 'all')));
        if ($status !== '' && $status !== 'all') {
            if (in_array($status, ['active', 'assignable'], true)) {
                $query->whereRaw('LOWER(status) = ?', ['active']);
            } else {
                $query->whereRaw('LOWER(status) = ?', [$status]);
            }
        }

        $vehicles = $query->get();
        $context = $this->manualVehicleListContext($vehicles->all());

        return $vehicles
            ->map(fn (ManualVehicle $vehicle): array => $this->formatManualVehicle($vehicle, $context))
            ->values()
            ->all();
    }

    private function loadFleetClients(array $context = []): array
    {
        if (! $this->fleetClientsTableAvailable()) {
            return [];
        }

        return FleetClient::query()
            ->orderBy('company_name')
            ->get()
            ->map(fn (FleetClient $client): array => $this->formatFleetClient($client, $context))
            ->values()
            ->all();
    }

    private function validateFleetClientPayload(Request $request, bool $partial = false, ?FleetClient $client = null): array
    {
        $nameRule = $client === null
            ? 'unique:fleet_clients,company_name'
            : 'unique:fleet_clients,company_name,'.$client->id;

        return $request->validate([
            'companyName' => [$partial ? 'sometimes' : 'required', 'string', 'max:255', $nameRule],
            'contactPersonName' => [$partial ? 'sometimes' : 'required', 'string', 'max:255'],
            'contactNumber' => [$partial ? 'sometimes' : 'required', 'string', 'max:120'],
            'email' => ['nullable', 'email', 'max:255'],
            'billingAddress' => [$partial ? 'sometimes' : 'required', 'string', 'max:5000'],
            'deliveryAddress' => ['nullable', 'string', 'max:5000'],
            'clientType' => ['nullable', 'string', 'in:Regular,Priority,One-time,regular,priority,one-time,one_time'],
            'paymentTerms' => ['nullable', 'string', 'in:COD,30 days net,60 days net,cod,30_days_net,60_days_net'],
            'freeDeliveryThreshold' => ['nullable', 'numeric', 'min:0', 'max:999999999'],
            'erpCustomerId' => ['nullable', 'string', 'max:120'],
            'status' => ['nullable', 'string', 'in:Active,Inactive,active,inactive'],
            'meta' => ['nullable', 'array'],
        ]);
    }

    private function fleetClientAttributes(array $validated, ?FleetClient $client = null): array
    {
        $attributes = [];
        $map = [
            'companyName' => 'company_name',
            'contactPersonName' => 'contact_person_name',
            'contactNumber' => 'contact_number',
            'email' => 'email',
            'billingAddress' => 'billing_address',
            'deliveryAddress' => 'delivery_address',
            'freeDeliveryThreshold' => 'free_delivery_threshold',
            'erpCustomerId' => 'erp_customer_id',
        ];

        foreach ($map as $incoming => $column) {
            if (! array_key_exists($incoming, $validated)) {
                continue;
            }

            $value = $validated[$incoming];
            if (is_string($value) || $value === null) {
                $value = $this->sanitizeText($value ?? '', '');
                if (in_array($column, ['email', 'delivery_address', 'erp_customer_id'], true) && $value === '') {
                    $value = null;
                }
            }
            $attributes[$column] = $value;
        }

        if (array_key_exists('clientType', $validated)) {
            $attributes['client_type'] = $this->normalizeFleetClientType((string) ($validated['clientType'] ?? 'regular'));
        } elseif ($client === null) {
            $attributes['client_type'] = 'regular';
        }

        if (array_key_exists('paymentTerms', $validated)) {
            $attributes['payment_terms'] = $this->normalizeFleetClientPaymentTerms((string) ($validated['paymentTerms'] ?? 'cod'));
        } elseif ($client === null) {
            $attributes['payment_terms'] = 'cod';
        }

        if (array_key_exists('status', $validated)) {
            $attributes['status'] = $this->normalizeFleetClientStatus((string) ($validated['status'] ?? 'active'));
            if ($attributes['status'] === 'inactive' && $client?->deactivated_at === null) {
                $attributes['deactivated_at'] = now();
            } elseif ($attributes['status'] === 'active') {
                $attributes['deactivated_at'] = null;
            }
        } elseif ($client === null) {
            $attributes['status'] = 'active';
        }

        if ($client === null && ! array_key_exists('free_delivery_threshold', $attributes)) {
            $attributes['free_delivery_threshold'] = (float) $this->systemSettingsValue('free_delivery_threshold', 100000);
        }

        if (array_key_exists('meta', $validated)) {
            $attributes['meta'] = $validated['meta'];
        }

        return $attributes;
    }

    private function normalizeFleetClientType(string $type): string
    {
        return match (strtolower(trim($type))) {
            'priority' => 'priority',
            'one-time', 'one_time', 'one time' => 'one_time',
            default => 'regular',
        };
    }

    private function normalizeFleetClientPaymentTerms(string $terms): string
    {
        return match (strtolower(trim($terms))) {
            '30 days net', '30_days_net', 'net 30' => '30_days_net',
            '60 days net', '60_days_net', 'net 60' => '60_days_net',
            default => 'cod',
        };
    }

    private function normalizeFleetClientStatus(string $status): string
    {
        return strtolower(trim($status)) === 'inactive' ? 'inactive' : 'active';
    }

    private function findFleetClient(string $clientId): ?FleetClient
    {
        if (! $this->fleetClientsTableAvailable()) {
            return null;
        }

        $id = str_replace('client-', '', trim($clientId));
        if (ctype_digit($id)) {
            return FleetClient::query()->find((int) $id);
        }

        return FleetClient::query()
            ->where('company_name', $this->sanitizeText($clientId, ''))
            ->orWhere('erp_customer_id', $clientId)
            ->first();
    }

    private function formatFleetClient(FleetClient $client, array $context = []): array
    {
        $company = $this->sanitizeText($client->company_name, 'Unknown Client');
        $metrics = $this->fleetClientMetrics($company, $context);

        return [
            'id' => 'client-'.$client->id,
            'localId' => (string) $client->id,
            'companyName' => $company,
            'contactPersonName' => $this->sanitizeText($client->contact_person_name, 'N/A'),
            'contactNumber' => $this->sanitizeText($client->contact_number, 'N/A'),
            'email' => $this->sanitizeText($client->email ?? '', 'N/A'),
            'billingAddress' => $this->sanitizeText($client->billing_address, 'N/A'),
            'deliveryAddress' => $this->sanitizeText($client->delivery_address ?? '', 'Same as billing address'),
            'clientType' => $client->client_type,
            'clientTypeLabel' => $this->fleetClientTypeLabel($client->client_type),
            'paymentTerms' => $client->payment_terms,
            'paymentTermsLabel' => $this->fleetClientPaymentTermsLabel($client->payment_terms),
            'freeDeliveryThreshold' => round((float) $client->free_delivery_threshold, 2),
            'freeDeliveryThresholdLabel' => $this->money((float) $client->free_delivery_threshold),
            'erpCustomerId' => $this->sanitizeText($client->erp_customer_id ?? '', 'N/A'),
            'status' => $client->status,
            'isActive' => $client->status === 'active',
            'hasHistory' => $metrics['totalTrips'] > 0 || $metrics['invoiceCount'] > 0,
            'totalTripsThisMonth' => $metrics['totalTripsThisMonth'],
            'totalTrips' => $metrics['totalTrips'],
            'totalInvoicedThisMonth' => $metrics['totalInvoicedThisMonth'],
            'totalInvoicedThisMonthLabel' => $this->money($metrics['totalInvoicedThisMonth']),
            'outstandingBalance' => $metrics['outstandingBalance'],
            'outstandingBalanceLabel' => $this->money($metrics['outstandingBalance']),
            'tripHistory' => $metrics['tripHistory'],
            'statementOfAccounts' => $metrics['statementOfAccounts'],
            'auditTrail' => is_array($client->audit_trail) ? $client->audit_trail : [],
            'deactivatedAt' => $client->deactivated_at?->toIso8601String(),
            'createdAt' => $client->created_at?->toIso8601String(),
            'updatedAt' => $client->updated_at?->toIso8601String(),
        ];
    }

    private function fleetClientMetrics(string $company, array $context): array
    {
        $companyKey = strtolower(trim($company));
        $trips = array_values(array_filter(
            is_array($context['trips'] ?? null) ? $context['trips'] : [],
            fn (array $trip): bool => strtolower(trim((string) ($trip['customer'] ?? $trip['client'] ?? ''))) === $companyKey
        ));
        $billings = array_values(array_filter(
            is_array($context['billings'] ?? null) ? $context['billings'] : [],
            fn (array $invoice): bool => strtolower(trim((string) ($invoice['client'] ?? ''))) === $companyKey
        ));

        $monthStart = now()->startOfMonth();
        $monthEnd = now()->endOfMonth();
        $tripsThisMonth = array_values(array_filter($trips, function (array $trip) use ($monthStart, $monthEnd): bool {
            $date = $this->parseDate($trip['scheduledDepartureAt'] ?? $trip['date'] ?? $trip['sortAt'] ?? null);

            return $date === null || $date->betweenIncluded($monthStart, $monthEnd);
        }));
        $billingsThisMonth = array_values(array_filter($billings, function (array $invoice) use ($monthStart, $monthEnd): bool {
            $date = $this->parseDate($invoice['issueDate'] ?? $invoice['date'] ?? $invoice['createdAt'] ?? null);
            if (strtolower((string) ($invoice['status'] ?? 'sent')) === 'voided') {
                return false;
            }

            return $date === null || $date->betweenIncluded($monthStart, $monthEnd);
        }));
        $outstanding = array_reduce($billings, function (float $sum, array $invoice): float {
            $status = strtolower((string) ($invoice['status'] ?? 'sent'));
            if (in_array($status, ['paid', 'voided'], true)) {
                return $sum;
            }

            return $sum + $this->parseMoney($invoice['amount'] ?? $invoice['total'] ?? 0);
        }, 0.0);

        $soaRows = is_array(data_get($context, 'soa.clients')) ? data_get($context, 'soa.clients') : [];
        $soa = collect($soaRows)->first(function (array $row) use ($companyKey): bool {
            return strtolower(trim((string) ($row['name'] ?? ''))) === $companyKey;
        }) ?? [
            'name' => $company,
            'invoices' => 0,
            'invoiceRows' => [],
            'total' => $this->money(0),
            'outstandingLabel' => $this->money(0),
        ];

        return [
            'totalTripsThisMonth' => count($tripsThisMonth),
            'totalTrips' => count($trips),
            'totalInvoicedThisMonth' => round(array_sum(array_map(fn (array $invoice): float => $this->parseMoney($invoice['amount'] ?? $invoice['total'] ?? 0), $billingsThisMonth)), 2),
            'outstandingBalance' => round($outstanding, 2),
            'invoiceCount' => count($billings),
            'tripHistory' => $trips,
            'statementOfAccounts' => $soa,
        ];
    }

    private function clientContextFromSnapshot(): array
    {
        $snapshot = $this->snapshot();

        return [
            'trips' => is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [],
            'billings' => is_array($snapshot['billings'] ?? null) ? $snapshot['billings'] : [],
            'soa' => is_array($snapshot['soa'] ?? null) ? $snapshot['soa'] : [],
        ];
    }

    private function fleetClientTypeLabel(string $type): string
    {
        return match ($type) {
            'priority' => 'Priority',
            'one_time' => 'One-time',
            default => 'Regular',
        };
    }

    private function fleetClientPaymentTermsLabel(string $terms): string
    {
        return match ($terms) {
            '30_days_net' => '30 days net',
            '60_days_net' => '60 days net',
            default => 'COD',
        };
    }

    private function appendFleetClientAudit(FleetClient $client, string $event, array $changes, Request $request): void
    {
        $auditTrail = is_array($client->audit_trail) ? $client->audit_trail : [];
        $auditTrail[] = [
            'event' => $event,
            'changes' => $changes,
            'actor' => $this->sanitizeText($request->user()?->name ?? $request->input('actor', 'system'), 'system'),
            'timestamp' => now()->toIso8601String(),
        ];
        $client->audit_trail = array_slice($auditTrail, -100);
    }

    private function fleetClientHasHistory(FleetClient $client): bool
    {
        $metrics = $this->fleetClientMetrics((string) $client->company_name, $this->clientContextFromSnapshot());

        return $metrics['totalTrips'] > 0 || $metrics['invoiceCount'] > 0;
    }

    private function freeDeliveryThresholdForCustomer(string $customer): float
    {
        $defaultThreshold = (float) $this->systemSettingsValue('free_delivery_threshold', 100000);
        if (! $this->fleetClientsTableAvailable()) {
            return $defaultThreshold;
        }

        if ($this->clientThresholdsByName === null) {
            $this->clientThresholdsByName = FleetClient::query()
                ->pluck('free_delivery_threshold', 'company_name')
                ->mapWithKeys(fn ($threshold, string $name): array => [strtolower(trim($name)) => (float) $threshold])
                ->all();
        }

        return $this->clientThresholdsByName[strtolower(trim($customer))] ?? $defaultThreshold;
    }

    private function validateManualVehiclePayload(Request $request, bool $partial = false, ?ManualVehicle $vehicle = null): array
    {
        $plateRule = $vehicle === null
            ? 'unique:manual_vehicles,plate_number'
            : 'unique:manual_vehicles,plate_number,'.$vehicle->id;

        return $request->validate([
            'plateNumber' => [$partial ? 'sometimes' : 'required', 'string', 'max:80', $plateRule],
            'vehicleType' => [$partial ? 'sometimes' : 'required', 'string', 'max:120'],
            'makeModel' => ['nullable', 'string', 'max:255'],
            'year' => ['nullable', 'integer', 'min:1950', 'max:'.(now()->year + 1)],
            'chassisNumber' => ['nullable', 'string', 'max:160'],
            'vin' => ['nullable', 'string', 'max:160'],
            'fuelType' => [$partial ? 'sometimes' : 'required', 'string', 'in:Diesel,Gasoline,Electric'],
            'fuelCapacityLiters' => ['nullable', 'numeric', 'min:0', 'max:100000'],
            'cargoCapacityKg' => [$partial ? 'sometimes' : 'required', 'numeric', 'min:1', 'max:1000000'],
            'geotabDeviceId' => ['nullable', 'string', 'max:120'],
            'registrationExpiryDate' => [$partial ? 'sometimes' : 'required', 'date'],
            'insuranceExpiryDate' => ['nullable', 'date'],
            'status' => ['nullable', 'string', 'in:Active,Under Maintenance,Inactive,active,under_maintenance,inactive,maintenance'],
            'meta' => ['nullable', 'array'],
        ]);
    }

    private function manualVehicleAttributes(array $validated, ?ManualVehicle $vehicle = null): array
    {
        $attributes = [];
        $map = [
            'plateNumber' => 'plate_number',
            'vehicleType' => 'vehicle_type',
            'makeModel' => 'make_model',
            'year' => 'year',
            'chassisNumber' => 'chassis_number',
            'vin' => 'vin',
            'fuelType' => 'fuel_type',
            'fuelCapacityLiters' => 'fuel_capacity_liters',
            'cargoCapacityKg' => 'cargo_capacity_kg',
            'geotabDeviceId' => 'geotab_device_id',
            'registrationExpiryDate' => 'registration_expiry_date',
            'insuranceExpiryDate' => 'insurance_expiry_date',
        ];

        foreach ($map as $incoming => $column) {
            if (! array_key_exists($incoming, $validated)) {
                continue;
            }
            $value = $validated[$incoming];
            if (in_array($column, ['plate_number', 'vehicle_type', 'make_model', 'chassis_number', 'vin', 'fuel_type', 'geotab_device_id'], true)) {
                $value = trim((string) ($value ?? ''));
                if ($column === 'plate_number') {
                    $value = strtoupper($value);
                }
                $value = $value !== '' ? $value : null;
            }
            $attributes[$column] = $value;
        }

        if (array_key_exists('status', $validated)) {
            $attributes['status'] = $this->normalizeManualVehicleStatus((string) ($validated['status'] ?? 'active'));
            if ($attributes['status'] === 'inactive' && $vehicle?->deactivated_at === null) {
                $attributes['deactivated_at'] = now();
            }
        } elseif ($vehicle === null) {
            $attributes['status'] = 'active';
        }

        if (array_key_exists('meta', $validated)) {
            $attributes['meta'] = $validated['meta'];
        }

        return $attributes;
    }

    private function normalizeManualVehicleStatus(string $status): string
    {
        return match (strtolower(trim($status))) {
            'under maintenance', 'maintenance', 'under_maintenance' => 'maintenance',
            'inactive', 'deactivated', 'retired' => 'inactive',
            default => 'active',
        };
    }

    private function findManualVehicle(string $vehicleId): ?ManualVehicle
    {
        if (! $this->manualVehiclesTableAvailable()) {
            return null;
        }

        $id = str_replace('manual-vehicle-', '', trim($vehicleId));
        if (ctype_digit($id)) {
            return ManualVehicle::query()->find((int) $id);
        }

        return ManualVehicle::query()
            ->where('plate_number', strtoupper($vehicleId))
            ->orWhere('geotab_device_id', $vehicleId)
            ->first();
    }

    private function formatManualVehicle(ManualVehicle $vehicle, array $context = []): array
    {
        $plate = $this->sanitizeText($vehicle->plate_number, 'UNKNOWN');
        $geotabId = trim((string) $vehicle->geotab_device_id);
        $trips = is_array($context['trips'] ?? null) ? $context['trips'] : [];
        $fuel = is_array($context['fuel'] ?? null) ? $context['fuel'] : [];
        $maintenanceByVehicle = is_array($context['maintenanceByVehicle'] ?? null) ? $context['maintenanceByVehicle'] : [];
        $maintenance = $maintenanceByVehicle[$plate] ?? ($geotabId !== '' ? ($maintenanceByVehicle[$geotabId] ?? null) : null);
        $maintenance ??= $this->manualVehicleMaintenanceRows($plate, $geotabId);
        $completedTrips = array_values(array_filter($trips, fn (array $trip): bool => (string) ($trip['vehicle'] ?? '') === $plate && strtolower((string) ($trip['status'] ?? '')) === 'completed'));
        $distanceKm = round(array_sum(array_map(fn (array $trip): float => (float) ($trip['distanceKm'] ?? 0), $completedTrips)), 2);
        $gpsDistanceByDevice = is_array($context['gpsDistanceByDevice'] ?? null) ? $context['gpsDistanceByDevice'] : [];
        $gpsDistanceKm = $geotabId !== '' && isset($gpsDistanceByDevice[$geotabId])
            ? (float) $gpsDistanceByDevice[$geotabId]
            : $this->gpsDistanceKmForVehicle($vehicle);
        if ($gpsDistanceKm > 0) {
            $distanceKm = $gpsDistanceKm;
        }

        $fuelHistory = array_values(array_filter($fuel, fn (array $row): bool => (string) ($row['vehicle'] ?? '') === $plate));
        $registrationDays = $vehicle->registration_expiry_date?->diffInDays(now(), false);
        $insuranceDays = $vehicle->insurance_expiry_date?->diffInDays(now(), false);
        $registrationWarningDays = max(0, (int) $this->systemSettingsValue('registration_expiry_warning_days', 30));
        $maintenancePredictions = is_array($context['maintenancePredictions'] ?? null) ? $context['maintenancePredictions'] : [];
        $maintenancePrediction = $maintenancePredictions[$plate] ?? $this->maintenancePredictionForVehicle($plate);
        $syncStates = is_array($context['syncStates'] ?? null) ? $context['syncStates'] : [];
        $syncState = $syncStates[(string) $vehicle->id] ?? $this->manualVehicleSyncState($vehicle);
        $pseudoDevice = [
            'id' => $geotabId !== '' ? $geotabId : 'manual-'.$vehicle->id,
            'name' => $plate,
            'comment' => trim((string) ($vehicle->make_model ?? '').' '.(string) ($vehicle->vehicle_type ?? '')),
            'fuelTankCapacity' => $vehicle->fuel_capacity_liters,
        ];
        $displayOdometerKm = $distanceKm > 100 ? $distanceKm : $this->estimatedOdometerKm($pseudoDevice);
        $engineHours = $this->estimatedEngineHours($pseudoDevice, $displayOdometerKm);
        $fuelEconomy = $this->estimatedFuelEconomyKmPerLiter($pseudoDevice, 0, 0);
        $fuelLevelRatio = $this->estimatedFuelLevelRatio($pseudoDevice, $vehicle->fuel_capacity_liters, 0, 0, $displayOdometerKm, $engineHours);
        $definitions = $this->diagnosticDefinitions();
        $fuelProfile = strtolower((string) ($vehicle->fuel_type ?? ''));
        $isElectric = str_contains($fuelProfile, 'electric')
            || str_contains($fuelProfile, 'ev')
            || str_contains($fuelProfile, 'battery')
            || str_contains($fuelProfile, 'hybrid');
        $diagnostics = $this->backfillVehicleTelemetry(
            $this->emptyTelemetryEntry($definitions),
            $definitions,
            $pseudoDevice,
            $vehicle->fuel_capacity_liters,
            $fuelLevelRatio,
            $displayOdometerKm,
            $engineHours,
            $vehicle->updated_at,
            null,
            null,
            $isElectric,
        );

        return [
            'id' => 'manual-vehicle-'.$vehicle->id,
            'localId' => (string) $vehicle->id,
            'source' => 'manual',
            'managedLocally' => true,
            'plate' => $plate,
            'plateNumber' => $plate,
            'vehicleType' => $this->sanitizeText($vehicle->vehicle_type, 'Other'),
            'truckType' => $this->sanitizeText($vehicle->vehicle_type, 'Other'),
            'makeModel' => $this->sanitizeText($vehicle->make_model ?? '', 'N/A'),
            'year' => $vehicle->year ?: 'N/A',
            'chassisNumber' => $this->sanitizeText($vehicle->chassis_number ?? '', 'N/A'),
            'vin' => $this->sanitizeText($vehicle->vin ?? '', 'N/A'),
            'fuelType' => $vehicle->fuel_type,
            'fuelCapacityLiters' => $vehicle->fuel_capacity_liters,
            'fuelCapacity' => $vehicle->fuel_capacity_liters !== null ? number_format((float) $vehicle->fuel_capacity_liters, 0, '.', '') : 'N/A',
            'cargoCapacityKg' => round((float) $vehicle->cargo_capacity_kg, 2),
            'geotabId' => $geotabId,
            'geotabDeviceId' => $geotabId,
            'registrationExpiryDate' => $vehicle->registration_expiry_date?->toDateString(),
            'insuranceExpiryDate' => $vehicle->insurance_expiry_date?->toDateString(),
            'registrationDaysRemaining' => $registrationDays !== null ? -$registrationDays : null,
            'insuranceDaysRemaining' => $insuranceDays !== null ? -$insuranceDays : null,
            'registrationExpiringSoon' => $registrationDays !== null && $registrationDays >= -$registrationWarningDays && $registrationDays <= 0,
            'insuranceExpiringSoon' => $insuranceDays !== null && $insuranceDays >= -$registrationWarningDays && $insuranceDays <= 0,
            'status' => $vehicle->status,
            'syncStatus' => $syncState['status'],
            'syncLabel' => $syncState['label'],
            'hasLocalGeotabChanges' => $syncState['status'] === 'local_modified',
            'canPushToGeotab' => $syncState['status'] === 'local_modified',
            'syncError' => $syncState['syncError'],
            'pendingWriteJobId' => $syncState['pendingWriteJobId'],
            'geotabSnapshot' => $vehicle->geotab_snapshot,
            'driver' => 'Unassigned',
            'mileage' => number_format($displayOdometerKm, 0),
            'odometerKm' => $displayOdometerKm,
            'engineHours' => $engineHours,
            'fuelLevelRatio' => $fuelLevelRatio,
            'fuelLevelSupported' => true,
            'fuelEconomyKmPerLiter' => $fuelEconomy,
            'diagnostics' => $diagnostics,
            'numTrips' => count($completedTrips),
            'totalTripsCompleted' => count($completedTrips),
            'totalKmDriven' => $displayOdometerKm,
            'totalRevenue' => (int) round(array_sum(array_map(fn (array $trip): float => $this->parseMoney($trip['amount'] ?? 0), $completedTrips))),
            'maintenanceHistory' => $maintenance,
            'fuelConsumptionHistory' => $fuelHistory,
            'nextMaintenancePrediction' => $maintenancePrediction,
            'daysUntilPredictedNextMaintenance' => $maintenancePrediction['daysRemaining'] ?? null,
            'nextMaintenance' => $maintenancePrediction['nextDueLabel'] ?? 'Monitor odometer',
            'isCommunicating' => false,
            'latitude' => 0,
            'longitude' => 0,
            'speed' => 0,
            'bearing' => 0,
            'healthStatus' => $vehicle->status === 'maintenance' ? 'warning' : 'healthy',
            'healthScore' => $vehicle->status === 'maintenance' ? 70 : 100,
            'lastUpdated' => $vehicle->updated_at?->toIso8601String(),
            'lastGeotabAt' => null,
            'deactivatedAt' => $vehicle->deactivated_at?->toIso8601String(),
            'createdAt' => $vehicle->created_at?->toIso8601String(),
            'updatedAt' => $vehicle->updated_at?->toIso8601String(),
        ];
    }

    /**
     * @param  array<int, ManualVehicle>  $vehicles
     * @return array<string, mixed>
     */
    private function manualVehicleListContext(array $vehicles): array
    {
        $snapshot = $this->snapshot();
        $trips = is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [];
        $fuel = is_array(data_get($snapshot, 'fuel.transactions')) ? data_get($snapshot, 'fuel.transactions') : [];
        $plates = [];
        $deviceIds = [];
        $vehicleIds = [];

        foreach ($vehicles as $vehicle) {
            $plate = strtoupper(trim((string) $vehicle->plate_number));
            $deviceId = trim((string) $vehicle->geotab_device_id);
            if ($plate !== '') {
                $plates[] = $plate;
            }
            if ($deviceId !== '') {
                $deviceIds[] = $deviceId;
            }
            $vehicleIds[] = (string) $vehicle->id;
        }

        $syncStates = $this->manualVehicleSyncStates($vehicleIds);
        foreach ($vehicles as $vehicle) {
            $vehicleId = (string) $vehicle->id;
            if (($vehicle->sync_status ?? null) === 'local_modified') {
                $syncStates[$vehicleId] = $this->manualVehicleSyncState($vehicle);

                continue;
            }
            if (isset($syncStates[$vehicleId])) {
                continue;
            }
            $syncStates[$vehicleId] = [
                'status' => $vehicle->sync_status ?: 'not_staged',
                'label' => match ($vehicle->sync_status) {
                    'synced' => 'GeoTab: Up to date',
                    'failed' => 'GeoTab: Sync failed',
                    'permanently_failed' => 'GeoTab: Permanently failed',
                    'pending_approval' => 'GeoTab: Push awaiting approval',
                    'approved', 'processing' => 'GeoTab: Push approved, executing',
                    'local_modified' => 'GeoTab: Local changes pending',
                    default => 'GeoTab: Never synced',
                },
                'pendingWriteJobId' => $vehicle->pending_write_job_id ? (string) $vehicle->pending_write_job_id : null,
                'syncError' => $vehicle->sync_error,
            ];
        }

        return [
            'trips' => $trips,
            'fuel' => $fuel,
            'maintenanceByVehicle' => $this->manualVehicleMaintenanceRowsByVehicle($plates, $deviceIds),
            'maintenancePredictions' => $this->maintenancePredictionsByPlate($plates),
            'gpsDistanceByDevice' => $this->gpsDistanceKmByDevice($deviceIds),
            'syncStates' => $syncStates,
        ];
    }

    private function mergeManualVehicles(array $vehiclesView, array $trips = [], array $fuel = []): array
    {
        if (! $this->manualVehiclesTableAvailable()) {
            return $vehiclesView;
        }

        $byPlate = [];
        $byGeotab = [];
        foreach ($vehiclesView as $index => $vehicle) {
            $plate = strtoupper(trim((string) ($vehicle['plate'] ?? '')));
            $geotabId = trim((string) ($vehicle['geotabId'] ?? ''));
            if ($plate !== '') {
                $byPlate[$plate] = $index;
            }
            if ($geotabId !== '') {
                $byGeotab[$geotabId] = $index;
            }
        }

        foreach (ManualVehicle::query()->orderBy('plate_number')->get() as $manualVehicle) {
            $formatted = $this->formatManualVehicle($manualVehicle, ['trips' => $trips, 'fuel' => $fuel]);
            $plate = strtoupper((string) $formatted['plate']);
            $geotabId = trim((string) ($formatted['geotabId'] ?? ''));
            $index = $geotabId !== '' && array_key_exists($geotabId, $byGeotab)
                ? $byGeotab[$geotabId]
                : ($byPlate[$plate] ?? null);

            if ($index !== null) {
                $vehiclesView[$index] = [
                    ...$vehiclesView[$index],
                    ...array_filter($formatted, fn ($value): bool => $value !== null && $value !== 'N/A'),
                    'source' => 'geotab_manual',
                    'managedLocally' => true,
                ];

                continue;
            }

            $vehiclesView[] = $formatted;
        }

        usort($vehiclesView, fn (array $a, array $b) => strcmp((string) ($a['plate'] ?? ''), (string) ($b['plate'] ?? '')));

        return $vehiclesView;
    }

    private function manualVehicleMaintenanceRows(string $plate, string $geotabId): array
    {
        if (! $this->maintenanceHistoryTableAvailable()) {
            return [];
        }

        return MaintenanceHistory::query()
            ->where(function ($query) use ($plate, $geotabId): void {
                $query->where('vehicle_plate', $plate);
                if ($geotabId !== '') {
                    $query->orWhere('vehicle_geotab_id', $geotabId);
                }
            })
            ->orderByDesc('recorded_at')
            ->get()
            ->map(fn (MaintenanceHistory $history): array => $this->formatMaintenanceHistory($history))
            ->values()
            ->all();
    }

    /**
     * @param  array<int, string>  $plates
     * @param  array<int, string>  $deviceIds
     * @return array<string, array<int, array<string, mixed>>>
     */
    private function manualVehicleMaintenanceRowsByVehicle(array $plates, array $deviceIds): array
    {
        if (! $this->maintenanceHistoryTableAvailable()) {
            return [];
        }

        $plates = array_values(array_unique(array_filter(array_map(fn (string $plate): string => strtoupper(trim($plate)), $plates))));
        $deviceIds = array_values(array_unique(array_filter(array_map(fn (string $id): string => trim($id), $deviceIds))));
        if ($plates === [] && $deviceIds === []) {
            return [];
        }

        $rows = MaintenanceHistory::query()
            ->where(function ($query) use ($plates, $deviceIds): void {
                if ($plates !== []) {
                    $query->whereIn('vehicle_plate', $plates);
                }
                if ($deviceIds !== []) {
                    $method = $plates === [] ? 'whereIn' : 'orWhereIn';
                    $query->{$method}('vehicle_geotab_id', $deviceIds);
                }
            })
            ->orderByDesc('recorded_at')
            ->get();

        $grouped = [];
        foreach ($rows as $history) {
            $formatted = $this->formatMaintenanceHistory($history);
            $plate = strtoupper(trim((string) $history->vehicle_plate));
            $deviceId = trim((string) $history->vehicle_geotab_id);
            if ($plate !== '') {
                $grouped[$plate][] = $formatted;
            }
            if ($deviceId !== '') {
                $grouped[$deviceId][] = $formatted;
            }
        }

        return $grouped;
    }

    private function maintenancePredictionForVehicle(string $plate): array
    {
        if (! $this->maintenanceHistoryTableAvailable()) {
            return ['nextDueLabel' => 'Monitor odometer'];
        }

        $latest = MaintenanceHistory::query()
            ->where('vehicle_plate', $plate)
            ->orderByDesc('recorded_at')
            ->first();

        if ($latest === null) {
            return ['nextDueLabel' => 'Monitor odometer'];
        }

        $nextDue = $latest->next_due_at ?: $latest->recorded_at?->copy()->addDays(180);
        $daysRemaining = $nextDue?->diffInDays(now(), false);
        $daysRemaining = $daysRemaining !== null ? (int) -$daysRemaining : null;

        return [
            'nextDueDate' => $nextDue?->toDateString(),
            'daysRemaining' => $daysRemaining,
            'nextDueLabel' => $nextDue !== null
                ? $nextDue->toDateString()
                : 'Monitor odometer',
        ];
    }

    /**
     * @param  array<int, string>  $plates
     * @return array<string, array<string, mixed>>
     */
    private function maintenancePredictionsByPlate(array $plates): array
    {
        if (! $this->maintenanceHistoryTableAvailable()) {
            return [];
        }

        $plates = array_values(array_unique(array_filter(array_map(fn (string $plate): string => strtoupper(trim($plate)), $plates))));
        if ($plates === []) {
            return [];
        }

        $latestByPlate = [];
        MaintenanceHistory::query()
            ->whereIn('vehicle_plate', $plates)
            ->orderBy('vehicle_plate')
            ->orderByDesc('recorded_at')
            ->get()
            ->each(function (MaintenanceHistory $history) use (&$latestByPlate): void {
                $plate = strtoupper(trim((string) $history->vehicle_plate));
                $latestByPlate[$plate] ??= $history;
            });

        $predictions = [];
        foreach ($latestByPlate as $plate => $latest) {
            $nextDue = $latest->next_due_at ?: $latest->recorded_at?->copy()->addDays(180);
            $daysRemaining = $nextDue?->diffInDays(now(), false);
            $predictions[$plate] = [
                'nextDueDate' => $nextDue?->toDateString(),
                'daysRemaining' => $daysRemaining !== null ? (int) -$daysRemaining : null,
                'nextDueLabel' => $nextDue !== null ? $nextDue->toDateString() : 'Monitor odometer',
            ];
        }

        return $predictions;
    }

    private function gpsDistanceKmForVehicle(ManualVehicle $vehicle): float
    {
        if (! Schema::hasTable('gps_logs') || trim((string) $vehicle->geotab_device_id) === '') {
            return 0.0;
        }

        $logs = GpsLog::query()
            ->where('device_geotab_id', $vehicle->geotab_device_id)
            ->orderBy('recorded_at')
            ->get(['latitude', 'longitude']);
        $distance = 0.0;
        $previous = null;
        foreach ($logs as $log) {
            $point = ['latitude' => (float) $log->latitude, 'longitude' => (float) $log->longitude];
            if ($previous !== null) {
                $distance += $this->haversineDistanceKm($previous['latitude'], $previous['longitude'], $point['latitude'], $point['longitude']);
            }
            $previous = $point;
        }

        return round($distance, 2);
    }

    /**
     * @param  array<int, string>  $deviceIds
     * @return array<string, float>
     */
    private function gpsDistanceKmByDevice(array $deviceIds): array
    {
        if (! Schema::hasTable('gps_logs')) {
            return [];
        }

        $deviceIds = array_values(array_unique(array_filter(array_map(fn (string $id): string => trim($id), $deviceIds))));
        if ($deviceIds === []) {
            return [];
        }

        $distances = [];
        $previousByDevice = [];
        GpsLog::query()
            ->whereIn('device_geotab_id', $deviceIds)
            ->orderBy('device_geotab_id')
            ->orderBy('recorded_at')
            ->get(['device_geotab_id', 'latitude', 'longitude'])
            ->each(function (GpsLog $log) use (&$distances, &$previousByDevice): void {
                $deviceId = trim((string) $log->device_geotab_id);
                $point = ['latitude' => (float) $log->latitude, 'longitude' => (float) $log->longitude];
                $previous = $previousByDevice[$deviceId] ?? null;
                if ($previous !== null) {
                    $distances[$deviceId] = ($distances[$deviceId] ?? 0.0)
                        + $this->haversineDistanceKm($previous['latitude'], $previous['longitude'], $point['latitude'], $point['longitude']);
                }
                $previousByDevice[$deviceId] = $point;
            });

        return array_map(fn (float $distance): float => round($distance, 2), $distances);
    }

    private function haversineDistanceKm(float $fromLat, float $fromLng, float $toLat, float $toLng): float
    {
        $earthRadiusKm = 6371.0;
        $latDelta = deg2rad($toLat - $fromLat);
        $lngDelta = deg2rad($toLng - $fromLng);
        $a = sin($latDelta / 2) ** 2
            + cos(deg2rad($fromLat)) * cos(deg2rad($toLat)) * sin($lngDelta / 2) ** 2;

        return $earthRadiusKm * (2 * atan2(sqrt($a), sqrt(1 - $a)));
    }

    private function manualVehicleSyncState(ManualVehicle $vehicle): array
    {
        if (($vehicle->sync_status ?? null) === 'local_modified') {
            return [
                'status' => 'local_modified',
                'label' => 'GeoTab: Local changes pending',
                'pendingWriteJobId' => null,
                'syncError' => null,
            ];
        }
        $latestJob = null;
        if ($this->writeBack->tableAvailable()) {
            $latestJob = GeotabWriteJob::query()
                ->where('local_type', 'manual_vehicle')
                ->where('local_id', (string) $vehicle->id)
                ->latest('updated_at')
                ->latest('id')
                ->first();
        }

        if ($latestJob?->status === 'succeeded') {
            return [
                'status' => 'synced',
                'label' => 'GeoTab: Up to date',
                'pendingWriteJobId' => null,
                'syncError' => null,
            ];
        }

        if ($latestJob !== null) {
            return [
                'status' => $this->syncStatusFromWriteBackJob($latestJob),
                'label' => $this->geotabSyncLabel($this->syncStatusFromWriteBackJob($latestJob)),
                'pendingWriteJobId' => (string) $latestJob->id,
                'syncError' => $latestJob->last_error,
            ];
        }

        return [
            'status' => $vehicle->sync_status ?: 'not_staged',
            'label' => match ($vehicle->sync_status) {
                'synced' => 'GeoTab: Up to date',
                'failed' => 'GeoTab: Sync failed',
                'permanently_failed' => 'GeoTab: Permanently failed',
                'pending_approval' => 'GeoTab: Push awaiting approval',
                'approved', 'processing' => 'GeoTab: Push approved, executing',
                'local_modified' => 'GeoTab: Local changes pending',
                default => 'GeoTab: Never synced',
            },
            'pendingWriteJobId' => $vehicle->pending_write_job_id ? (string) $vehicle->pending_write_job_id : null,
            'syncError' => $vehicle->sync_error,
        ];
    }

    /**
     * @param  array<int, string>  $vehicleIds
     * @return array<string, array<string, mixed>>
     */
    private function manualVehicleSyncStates(array $vehicleIds): array
    {
        $vehicleIds = array_values(array_unique(array_filter($vehicleIds, fn (string $id): bool => $id !== '')));
        if ($vehicleIds === [] || ! $this->writeBack->tableAvailable()) {
            return [];
        }

        $latestJobs = [];
        GeotabWriteJob::query()
            ->where('local_type', 'manual_vehicle')
            ->whereIn('local_id', $vehicleIds)
            ->orderByDesc('updated_at')
            ->orderByDesc('id')
            ->get()
            ->each(function (GeotabWriteJob $job) use (&$latestJobs): void {
                $localId = (string) $job->local_id;
                $latestJobs[$localId] ??= $job;
            });

        $states = [];
        foreach ($vehicleIds as $vehicleId) {
            $job = $latestJobs[$vehicleId] ?? null;
            if ($job?->status === 'succeeded') {
                $states[$vehicleId] = [
                    'status' => 'synced',
                    'label' => 'GeoTab: Up to date',
                    'pendingWriteJobId' => null,
                    'syncError' => null,
                ];

                continue;
            }

            if ($job !== null) {
                $states[$vehicleId] = [
                    'status' => $this->syncStatusFromWriteBackJob($job),
                    'label' => $this->geotabSyncLabel($this->syncStatusFromWriteBackJob($job)),
                    'pendingWriteJobId' => (string) $job->id,
                    'syncError' => $job->last_error,
                ];
            }
        }

        return $states;
    }

    private function stageManualVehicleWriteBack(ManualVehicle $vehicle, string $action, string $createdBy = 'system'): void
    {
        if (! $this->writeBack->tableAvailable()) {
            return;
        }

        $deviceId = trim((string) $vehicle->geotab_device_id);
        if ($deviceId === '') {
            $vehicle->forceFill([
                'sync_status' => 'not_staged',
                'sync_error' => null,
                'pending_write_job_id' => null,
            ])->saveQuietly();

            return;
        }

        $payload = $this->manualVehicleWriteBackPayload($vehicle);

        $job = $this->writeBack->createJob(
            $action,
            'Device',
            $payload,
            'manual_vehicle',
            (string) $vehicle->id,
            'manual-vehicle:'.$vehicle->id.':'.$action.':'.($vehicle->updated_at?->timestamp ?? time()),
            $createdBy,
            $this->buildGeotabPreviewPayload('Vehicle', (string) $vehicle->plate_number, $payload, $vehicle->geotab_snapshot ?? null),
        );

        if ($job === null) {
            return;
        }

        $vehicle->forceFill([
            'sync_status' => 'pending_approval',
            'sync_error' => null,
            'pending_write_job_id' => $job->id,
        ])->saveQuietly();
    }

    private function manualVehicleWriteBackPayload(ManualVehicle $vehicle): array
    {
        return [
            'entity' => array_filter([
                'id' => trim((string) $vehicle->geotab_device_id),
                'name' => $vehicle->plate_number,
                'licensePlate' => $vehicle->plate_number,
                'vehicleIdentificationNumber' => $vehicle->vin,
                'comment' => trim(implode(' | ', array_filter([
                    $vehicle->vehicle_type,
                    $vehicle->make_model,
                    'Cargo '.$vehicle->cargo_capacity_kg.' kg',
                ]))),
            ], fn ($value): bool => $value !== null && $value !== ''),
        ];
    }

    private function markManualVehicleGeotabDirty(ManualVehicle $vehicle): void
    {
        $payload = $this->manualVehicleWriteBackPayload($vehicle);
        $vehicle->forceFill([
            'sync_status' => $this->payloadMatchesGeotabSnapshot($payload, $vehicle->geotab_snapshot ?? null) ? 'synced' : 'local_modified',
            'sync_error' => null,
            'pending_write_job_id' => null,
        ])->saveQuietly();
    }

    public function pushManualVehicleToGeotab(Request $request, string $vehicleId): JsonResponse
    {
        $vehicle = $this->findManualVehicle($vehicleId);
        if ($vehicle === null) {
            return $this->respondError('Vehicle not found.', 404);
        }

        if ($this->payloadMatchesGeotabSnapshot($this->manualVehicleWriteBackPayload($vehicle), $vehicle->geotab_snapshot ?? null)) {
            return $this->respondData([
                ...$this->formatManualVehicle($vehicle),
                'geotabAlreadyUpToDate' => true,
                'message' => 'GeoTab is already up to date.',
            ]);
        }

        $payload = $this->manualVehicleWriteBackPayload($vehicle);
        if ($this->isGeotabPreviewRequest($request)) {
            return $this->respondData([
                ...$this->formatManualVehicle($vehicle),
                ...$this->pendingGeotabPushMetadata('manual_vehicle', (string) $vehicle->id),
                'message' => 'Review this GeoTab payload before staging it for approval.',
                'previewOnly' => true,
                'preview' => $payload,
                'previewPayload' => $this->buildGeotabPreviewPayload('Vehicle', (string) $vehicle->plate_number, $payload, $vehicle->geotab_snapshot ?? null),
            ]);
        }

        $this->stageManualVehicleWriteBack($vehicle, 'vehicle.update_device', $this->geotabActorFromRequest($request));
        $this->clearFleetCaches();

        return $this->respondData([
            ...$this->formatManualVehicle($vehicle->refresh()),
            'message' => 'GeoTab push request staged for admin approval.',
            'preview' => $payload,
        ]);
    }

    private function maybeStoreVehicleExpiryNotification(ManualVehicle $vehicle, string $reason): void
    {
        $warningDays = max(0, (int) $this->systemSettingsValue('registration_expiry_warning_days', 30));
        foreach ([
            'registration' => $vehicle->registration_expiry_date,
            'insurance' => $vehicle->insurance_expiry_date,
        ] as $type => $date) {
            if ($date === null) {
                continue;
            }
            $days = -$date->diffInDays(now(), false);
            if ($days < 0 || $days > $warningDays) {
                continue;
            }

            $key = 'vehicle-'.$type.'-expiry-'.$vehicle->id.'-'.$date->toDateString();
            $this->storeCustomNotification(
                'maintenance',
                ucfirst($type).' Expiry Reminder',
                $vehicle->plate_number.' '.$type.' expires in '.$days.' day'.($days === 1 ? '' : 's').'.',
                [
                    'notificationId' => $key,
                    'vehicleId' => $vehicle->id,
                    'vehiclePlate' => $vehicle->plate_number,
                    'expiryType' => $type,
                    'expiryDate' => $date->toDateString(),
                    'reason' => $reason,
                    'url' => '/vehicles',
                    'tag' => $key,
                ],
            );
        }
    }

    private function manualVehicleHasActiveTrip(ManualVehicle $vehicle): bool
    {
        $plate = strtoupper(trim((string) $vehicle->plate_number));
        $geotabId = trim((string) $vehicle->geotab_device_id);
        $activeStatuses = ['dispatched', 'inprogress', 'in progress', 'in transit', 'on trip', 'active'];
        foreach ($this->snapshot()['trips'] ?? [] as $trip) {
            $status = strtolower(trim((string) ($trip['status'] ?? '')));
            if (! in_array($status, $activeStatuses, true)) {
                continue;
            }
            $tripVehicle = strtoupper(trim((string) ($trip['vehicle'] ?? '')));
            $tripDevice = trim((string) ($trip['deviceGeotabId'] ?? $trip['geotabId'] ?? ''));
            if ($tripVehicle === $plate || ($geotabId !== '' && $tripDevice === $geotabId)) {
                return true;
            }
        }

        return false;
    }

    private function manualVehicleHasTripHistory(ManualVehicle $vehicle): bool
    {
        $vehicleKeys = array_filter([
            strtolower(trim((string) $vehicle->id)),
            strtolower(trim('manual-vehicle-'.$vehicle->id)),
            strtolower(trim((string) $vehicle->plate_number)),
            strtolower(trim((string) $vehicle->geotab_device_id)),
        ]);
        if ($vehicleKeys === []) {
            return false;
        }

        foreach (($this->snapshot()['trips'] ?? []) as $trip) {
            if (! is_array($trip)) {
                continue;
            }

            $tripVehicleKeys = array_filter([
                strtolower(trim((string) ($trip['vehicle'] ?? ''))),
                strtolower(trim((string) ($trip['vehiclePlate'] ?? ''))),
                strtolower(trim((string) ($trip['assignedVehicle'] ?? ''))),
                strtolower(trim((string) ($trip['vehicleId'] ?? ''))),
                strtolower(trim((string) ($trip['assignedVehicleId'] ?? ''))),
                strtolower(trim((string) ($trip['deviceGeotabId'] ?? ''))),
                strtolower(trim((string) ($trip['assignedVehicleGeotabId'] ?? ''))),
                strtolower(trim((string) ($trip['geotabId'] ?? ''))),
            ]);
            if (array_intersect($vehicleKeys, $tripVehicleKeys) !== []) {
                return true;
            }
        }

        return false;
    }

    private function filterFuelPayloadByVehicle(array $fuel, string $selectedVehicle): array
    {
        $selectedVehicle = trim($selectedVehicle);
        if ($selectedVehicle === '') {
            return $fuel;
        }

        $identifiers = $this->fuelVehicleIdentifiers($selectedVehicle);
        $matchesVehicle = fn (array $row): bool => $this->fuelRowMatchesVehicle($row, $identifiers);
        $events = array_values(array_filter(
            is_array($fuel['events'] ?? null) ? $fuel['events'] : [],
            $matchesVehicle,
        ));
        $usage = array_values(array_filter(
            is_array($fuel['usageByVehicle'] ?? null) ? $fuel['usageByVehicle'] : [],
            $matchesVehicle,
        ));
        $transactions = array_values(array_filter(
            is_array($fuel['transactions'] ?? null) ? $fuel['transactions'] : [],
            $matchesVehicle,
        ));
        $chargeEvents = array_values(array_filter(
            is_array($fuel['chargeEvents'] ?? null) ? $fuel['chargeEvents'] : [],
            $matchesVehicle,
        ));
        $normalizedEvents = array_values(array_filter(
            is_array($fuel['normalizedEvents'] ?? null) ? $fuel['normalizedEvents'] : [],
            $matchesVehicle,
        ));
        $confirmedEvents = array_values(array_filter(
            is_array($fuel['confirmedEvents'] ?? null) ? $fuel['confirmedEvents'] : [],
            $matchesVehicle,
        ));
        $suggestedEvents = array_values(array_filter(
            is_array($fuel['suggestedEvents'] ?? null) ? $fuel['suggestedEvents'] : [],
            $matchesVehicle,
        ));
        $spendRows = $transactions !== [] ? $transactions : $events;
        $totals = $this->fuelTotalsFromRows($fuel, $spendRows, $usage, $chargeEvents);

        return [
            ...$fuel,
            'events' => $events,
            'usageByVehicle' => $usage,
            'transactions' => $transactions,
            'chargeEvents' => $chargeEvents,
            'normalizedEvents' => $normalizedEvents,
            'confirmedEvents' => $confirmedEvents,
            'suggestedEvents' => $suggestedEvents,
            'stationMatches' => array_values(array_filter($normalizedEvents, fn (array $row): bool => filled($row['stationPlaceId'] ?? null))),
            'reviewSummary' => [
                'confirmed' => count(array_filter($normalizedEvents, fn (array $row): bool => ($row['reviewStatus'] ?? '') === 'confirmed')),
                'needsReview' => count(array_filter($normalizedEvents, fn (array $row): bool => ($row['reviewStatus'] ?? '') === 'needs_review')),
                'rejected' => count(array_filter($normalizedEvents, fn (array $row): bool => ($row['reviewStatus'] ?? '') === 'rejected')),
                'exactTransactions' => count(array_filter($normalizedEvents, fn (array $row): bool => ($row['eventType'] ?? '') === 'confirmed_transaction')),
            ],
            'totals' => $totals,
            'selectedVehicle' => $selectedVehicle,
        ];
    }

    /**
     * @return array<int, string>
     */
    private function fuelVehicleIdentifiers(string $selectedVehicle): array
    {
        $identifiers = [strtolower(trim($selectedVehicle))];
        if ($this->manualVehiclesTableAvailable()) {
            $managed = ManualVehicle::query()
                ->whereRaw('LOWER(plate_number) = ?', [strtolower(trim($selectedVehicle))])
                ->orWhere('geotab_device_id', $selectedVehicle)
                ->first();
            if ($managed !== null) {
                $identifiers[] = strtolower(trim((string) $managed->plate_number));
                $identifiers[] = strtolower(trim((string) $managed->geotab_device_id));
            }
        }

        foreach (($this->snapshot()['vehicles'] ?? []) as $vehicle) {
            if (! is_array($vehicle)) {
                continue;
            }
            $plate = strtolower(trim((string) ($vehicle['plate'] ?? '')));
            $deviceId = strtolower(trim((string) ($vehicle['geotabId'] ?? '')));
            if (in_array($plate, $identifiers, true) || in_array($deviceId, $identifiers, true)) {
                $identifiers[] = $plate;
                $identifiers[] = $deviceId;
            }
        }

        return array_values(array_unique(array_filter($identifiers)));
    }

    /**
     * @param  array<int, string>  $identifiers
     */
    private function fuelRowMatchesVehicle(array $row, array $identifiers): bool
    {
        $values = array_filter(array_map(
            fn (string $key): string => strtolower(trim((string) ($row[$key] ?? ''))),
            ['vehicle', 'plate', 'vehiclePlate', 'geotabId', 'deviceId', 'vehicleGeotabId'],
        ));

        return array_intersect($identifiers, $values) !== [];
    }

    private function requestChangesVehicleToInactive(Request $request): bool
    {
        if (! $request->has('status')) {
            return false;
        }

        return $this->normalizeManualVehicleStatus((string) $request->input('status')) === 'inactive';
    }

    private function validateMaintenanceHistoryPayload(Request $request, bool $partial = false): array
    {
        $validated = $request->validate([
            'vehicleGeotabId' => ['nullable', 'string', 'max:120'],
            'vehiclePlate' => [$partial ? 'sometimes' : 'required', 'string', 'max:120'],
            'type' => [$partial ? 'sometimes' : 'required', 'string', 'max:120'],
            'description' => [$partial ? 'sometimes' : 'required', 'string', 'max:2000'],
            'status' => ['nullable', 'string', 'max:80'],
            'source' => ['nullable', 'string', 'max:80'],
            'recordedAt' => [$partial ? 'sometimes' : 'required', 'date'],
            'nextDueAt' => ['nullable', 'date'],
            'odometerKm' => [$partial ? 'sometimes' : 'required', 'numeric', 'min:0', 'max:99999999'],
            'cost' => ['nullable', 'numeric', 'min:0'],
            'provider' => ['nullable', 'string', 'max:255'],
            'notes' => ['nullable', 'string', 'max:5000'],
            'proofFileName' => ['nullable', 'string', 'max:255'],
            'proofFileType' => ['nullable', 'string', 'max:80'],
            'proofDataUrl' => ['nullable', 'string', 'max:14000000'],
            'voidReason' => ['nullable', 'string', 'max:2000'],
            'meta' => ['nullable', 'array'],
        ]);
        $this->validateProofDataUrl($validated['proofDataUrl'] ?? null, 'proofDataUrl', requireDataUrl: true);

        return $validated;
    }

    private function maintenanceHistoryAttributes(array $validated, ?MaintenanceHistory $history = null): array
    {
        $attributes = [];
        if (array_key_exists('vehicleGeotabId', $validated)) {
            $attributes['vehicle_geotab_id'] = trim((string) ($validated['vehicleGeotabId'] ?? '')) ?: null;
        }
        if (array_key_exists('vehiclePlate', $validated)) {
            $attributes['vehicle_plate'] = strtoupper(trim((string) ($validated['vehiclePlate'] ?? ''))) ?: null;
        }
        if (array_key_exists('type', $validated)) {
            $attributes['type'] = $this->sanitizeText($validated['type'], 'Other');
        }
        if (array_key_exists('description', $validated)) {
            $attributes['description'] = $this->sanitizeText($validated['description'], '');
        }
        if (array_key_exists('status', $validated)) {
            $attributes['status'] = $this->normalizeMaintenanceStatus((string) ($validated['status'] ?? 'recorded'));
        } elseif ($history === null) {
            $attributes['status'] = 'recorded';
        }
        if (array_key_exists('source', $validated)) {
            $attributes['source'] = $this->normalizeMaintenanceSource((string) ($validated['source'] ?? 'manual'));
        } elseif ($history === null) {
            $attributes['source'] = 'manual';
        }
        if (array_key_exists('recordedAt', $validated)) {
            $attributes['recorded_at'] = Carbon::parse($validated['recordedAt']);
        } elseif ($history === null) {
            $attributes['recorded_at'] = now();
        }
        if (array_key_exists('nextDueAt', $validated)) {
            $attributes['next_due_at'] = trim((string) ($validated['nextDueAt'] ?? '')) !== ''
                ? Carbon::parse($validated['nextDueAt'])
                : null;
        }
        if (array_key_exists('odometerKm', $validated)) {
            $attributes['odometer_km'] = $validated['odometerKm'];
        }
        if (array_key_exists('cost', $validated)) {
            $attributes['cost'] = $validated['cost'] ?? null;
        }
        if (array_key_exists('provider', $validated)) {
            $attributes['provider'] = $this->nullableCleanText($validated['provider'] ?? '');
        }
        if (array_key_exists('notes', $validated)) {
            $attributes['notes'] = $this->nullableCleanText($validated['notes'] ?? '');
        }
        foreach ([
            'proofFileName' => 'proof_file_name',
            'proofFileType' => 'proof_file_type',
            'proofDataUrl' => 'proof_file_data',
        ] as $incoming => $column) {
            if (array_key_exists($incoming, $validated)) {
                $attributes[$column] = $this->nullableCleanText($validated[$incoming] ?? '');
            }
        }
        if (array_key_exists('voidReason', $validated)) {
            $reason = $this->sanitizeText($validated['voidReason'] ?? '', '');
            if ($reason !== '') {
                $attributes['status'] = 'voided';
                $attributes['void_reason'] = $reason;
                $attributes['voided_at'] = now();
            }
        }
        if (array_key_exists('meta', $validated)) {
            $attributes['meta'] = [
                ...(is_array($history?->meta) ? $history->meta : []),
                ...($validated['meta'] ?? []),
            ];
        }

        return $attributes;
    }

    private function normalizeMaintenanceStatus(string $status): string
    {
        return match (strtolower(trim($status))) {
            'voided', 'void' => 'voided',
            'due', 'overdue', 'scheduled' => strtolower(trim($status)),
            default => 'recorded',
        };
    }

    private function normalizeMaintenanceSource(string $source): string
    {
        return str_starts_with(strtolower(trim($source)), 'geotab') ? 'geotab' : 'manual';
    }

    private function validateMaintenanceWorkOrderPayload(Request $request, bool $partial = false): array
    {
        $validated = $request->validate([
            'vehicleGeotabId' => ['nullable', 'string', 'max:120'],
            'vehiclePlate' => [$partial ? 'sometimes' : 'required', 'string', 'max:120'],
            'title' => [$partial ? 'sometimes' : 'required', 'string', 'max:255'],
            'description' => [$partial ? 'sometimes' : 'required', 'string', 'max:3000'],
            'priority' => ['nullable', 'string', 'max:40'],
            'status' => ['nullable', 'string', 'max:40'],
            'sourceType' => ['nullable', 'string', 'max:80'],
            'sourceRecordId' => ['nullable', 'string', 'max:255'],
            'sourceSummary' => ['nullable', 'string', 'max:2000'],
            'assignedTo' => ['nullable', 'string', 'max:255'],
            'scheduledAt' => ['nullable', 'date'],
            'estimatedCost' => ['nullable', 'numeric', 'min:0'],
            'actualCost' => ['nullable', 'numeric', 'min:0'],
            'notes' => ['nullable', 'string', 'max:5000'],
            'voidReason' => ['nullable', 'string', 'max:2000'],
            'attachments' => ['nullable', 'array', 'max:12'],
            'attachments.*.fileName' => ['required_with:attachments', 'string', 'max:255'],
            'attachments.*.fileType' => ['required_with:attachments', 'string', 'max:80'],
            'attachments.*.dataUrl' => ['required_with:attachments', 'string', 'max:14000000'],
            'attachments.*.kind' => ['nullable', 'string', 'max:80'],
            'attachments.*.notes' => ['nullable', 'string', 'max:1000'],
            'actor' => ['nullable', 'string', 'max:255'],
            'meta' => ['nullable', 'array'],
        ]);

        foreach (($validated['attachments'] ?? []) as $index => $attachment) {
            $this->validateProofDataUrl($attachment['dataUrl'] ?? null, "attachments.$index.dataUrl", requireDataUrl: true);
        }

        return $validated;
    }

    private function maintenanceWorkOrderAttributes(array $validated, ?MaintenanceWorkOrder $workOrder = null): array
    {
        $attributes = [];
        if (array_key_exists('vehicleGeotabId', $validated)) {
            $attributes['vehicle_geotab_id'] = trim((string) ($validated['vehicleGeotabId'] ?? '')) ?: null;
        }
        if (array_key_exists('vehiclePlate', $validated)) {
            $attributes['vehicle_plate'] = strtoupper(trim((string) ($validated['vehiclePlate'] ?? ''))) ?: null;
        }
        if (array_key_exists('title', $validated)) {
            $attributes['title'] = $this->sanitizeText($validated['title'], 'Maintenance Work Order');
        }
        if (array_key_exists('description', $validated)) {
            $attributes['description'] = $this->sanitizeText($validated['description'], '');
        }
        if (array_key_exists('priority', $validated)) {
            $attributes['priority'] = $this->normalizeWorkOrderPriority((string) ($validated['priority'] ?? 'medium'));
        } elseif ($workOrder === null) {
            $attributes['priority'] = 'medium';
        }
        if (array_key_exists('status', $validated)) {
            $attributes['status'] = $this->normalizeWorkOrderStatus((string) ($validated['status'] ?? 'open'));
        } elseif ($workOrder === null) {
            $attributes['status'] = 'open';
        }
        if (array_key_exists('sourceType', $validated)) {
            $attributes['source_type'] = $this->normalizeWorkOrderSource((string) ($validated['sourceType'] ?? 'manual'));
        } elseif ($workOrder === null) {
            $attributes['source_type'] = 'manual';
        }
        if (array_key_exists('sourceRecordId', $validated)) {
            $attributes['source_record_id'] = $this->nullableCleanText($validated['sourceRecordId'] ?? '');
        }
        if (array_key_exists('sourceSummary', $validated)) {
            $attributes['source_summary'] = $this->nullableCleanText($validated['sourceSummary'] ?? '');
        }
        if (array_key_exists('assignedTo', $validated)) {
            $attributes['assigned_to'] = $this->nullableCleanText($validated['assignedTo'] ?? '');
            if (($attributes['assigned_to'] ?? null) !== null && (($workOrder?->status ?? $attributes['status'] ?? 'open') === 'open')) {
                $attributes['status'] = 'assigned';
            }
        }
        if (array_key_exists('scheduledAt', $validated)) {
            $attributes['scheduled_at'] = trim((string) ($validated['scheduledAt'] ?? '')) !== ''
                ? Carbon::parse($validated['scheduledAt'])
                : null;
        }
        if (array_key_exists('estimatedCost', $validated)) {
            $attributes['estimated_cost'] = $validated['estimatedCost'] ?? null;
        }
        if (array_key_exists('actualCost', $validated)) {
            $attributes['actual_cost'] = $validated['actualCost'] ?? null;
        }
        if (array_key_exists('notes', $validated)) {
            $attributes['notes'] = $this->nullableCleanText($validated['notes'] ?? '');
        }
        if (array_key_exists('attachments', $validated)) {
            $attributes['attachments'] = array_values(array_map(
                fn (array $attachment): array => [
                    'fileName' => $this->sanitizeText($attachment['fileName'] ?? '', 'attachment'),
                    'fileType' => $this->sanitizeText($attachment['fileType'] ?? '', 'application/octet-stream'),
                    'dataUrl' => (string) ($attachment['dataUrl'] ?? ''),
                    'kind' => $this->sanitizeText($attachment['kind'] ?? 'proof', 'proof'),
                    'notes' => $this->nullableCleanText($attachment['notes'] ?? ''),
                    'uploadedAt' => $attachment['uploadedAt'] ?? now()->toIso8601String(),
                ],
                $validated['attachments'] ?? [],
            ));
        }
        if (array_key_exists('voidReason', $validated)) {
            $reason = $this->sanitizeText($validated['voidReason'] ?? '', '');
            if ($reason !== '') {
                $attributes['status'] = 'voided';
                $attributes['void_reason'] = $reason;
            }
        }
        if (array_key_exists('meta', $validated)) {
            $attributes['meta'] = [
                ...(is_array($workOrder?->meta) ? $workOrder->meta : []),
                ...($validated['meta'] ?? []),
            ];
        }

        return $attributes;
    }

    private function normalizeWorkOrderPriority(string $priority): string
    {
        return match (strtolower(trim($priority))) {
            'critical', 'high', 'medium', 'low' => strtolower(trim($priority)),
            default => 'medium',
        };
    }

    private function normalizeWorkOrderStatus(string $status): string
    {
        return match (strtolower(str_replace([' ', '-'], '_', trim($status)))) {
            'assigned' => 'assigned',
            'in_progress', 'started' => 'in_progress',
            'waiting_parts', 'waiting_for_parts' => 'waiting_parts',
            'completed', 'complete' => 'completed',
            'verified', 'closed' => 'verified',
            'voided', 'void' => 'voided',
            default => 'open',
        };
    }

    private function normalizeWorkOrderSource(string $source): string
    {
        return match (strtolower(str_replace([' ', '-'], '_', trim($source)))) {
            'geotab_fault', 'fault' => 'geotab_fault',
            'geotab_dvir', 'dvir' => 'geotab_dvir',
            'geotab_status', 'device_status', 'status' => 'geotab_status',
            'service_threshold', 'threshold' => 'service_threshold',
            default => 'manual',
        };
    }

    private function applyWorkOrderStatusTimestamps(MaintenanceWorkOrder $workOrder, string $beforeStatus, string $nextStatus): void
    {
        if ($beforeStatus === $nextStatus) {
            return;
        }

        $workOrder->status = $nextStatus;
        if ($nextStatus === 'in_progress' && $workOrder->started_at === null) {
            $workOrder->started_at = now();
        }
        if ($nextStatus === 'completed' && $workOrder->completed_at === null) {
            $workOrder->completed_at = now();
        }
        if ($nextStatus === 'verified' && $workOrder->verified_at === null) {
            $workOrder->verified_at = now();
            if ($workOrder->completed_at === null) {
                $workOrder->completed_at = now();
            }
        }
    }

    private function maintenanceWorkOrderActor(Request $request): string
    {
        return $this->sanitizeText(
            $request->input('actor')
                ?: $request->header('X-Pioneer-User')
                ?: $request->header('X-User-Name')
                ?: $request->user()?->name
                ?: 'maintenance staff',
            'maintenance staff',
        );
    }

    private function maintenanceWorkOrderAudit(string $event, string $actor, array $context = []): array
    {
        return [
            'event' => $event,
            'actor' => $this->sanitizeText($actor, 'maintenance staff'),
            'timestamp' => now()->toIso8601String(),
            'context' => $context,
        ];
    }

    private function formatMaintenanceWorkOrder(MaintenanceWorkOrder $workOrder): array
    {
        $sourceType = $this->normalizeWorkOrderSource((string) $workOrder->source_type);
        $attachments = array_values(is_array($workOrder->attachments) ? $workOrder->attachments : []);

        return [
            'id' => (string) $workOrder->id,
            'workOrderId' => 'WO-'.str_pad((string) $workOrder->id, 5, '0', STR_PAD_LEFT),
            'vehicleGeotabId' => $workOrder->vehicle_geotab_id,
            'vehiclePlate' => $workOrder->vehicle_plate ?: 'N/A',
            'vehicle' => $workOrder->vehicle_plate ?: 'N/A',
            'title' => $workOrder->title,
            'description' => $workOrder->description,
            'priority' => ucfirst($workOrder->priority ?: 'medium'),
            'priorityKey' => $workOrder->priority ?: 'medium',
            'status' => $workOrder->status ?: 'open',
            'statusLabel' => $this->workOrderStatusLabel($workOrder->status ?: 'open'),
            'sourceType' => $sourceType,
            'sourceLabel' => $this->workOrderSourceLabel($sourceType),
            'sourceRecordId' => $workOrder->source_record_id,
            'sourceSummary' => $workOrder->source_summary,
            'isNativeWorkOrder' => true,
            'isDerivedWorkOrder' => false,
            'isGeotabBacked' => $sourceType !== 'manual',
            'assignedTo' => $workOrder->assigned_to ?: 'Unassigned',
            'scheduledDate' => $this->displayShortDate($workOrder->scheduled_at),
            'scheduledAt' => $workOrder->scheduled_at?->toIso8601String(),
            'startedAt' => $workOrder->started_at?->toIso8601String(),
            'completedAt' => $workOrder->completed_at?->toIso8601String(),
            'verifiedAt' => $workOrder->verified_at?->toIso8601String(),
            'estimatedCost' => $workOrder->estimated_cost,
            'actualCost' => $workOrder->actual_cost,
            'estimatedCostLabel' => $workOrder->estimated_cost !== null ? $this->money((float) $workOrder->estimated_cost) : 'N/A',
            'actualCostLabel' => $workOrder->actual_cost !== null ? $this->money((float) $workOrder->actual_cost) : 'N/A',
            'cost' => $workOrder->actual_cost !== null ? $this->money((float) $workOrder->actual_cost) : ($workOrder->estimated_cost !== null ? $this->money((float) $workOrder->estimated_cost) : 'N/A'),
            'notes' => $workOrder->notes ?: '',
            'voidReason' => $workOrder->void_reason,
            'attachments' => array_values(array_map(
                fn (array $attachment, int $index): array => [
                    'index' => $index,
                    'fileName' => $attachment['fileName'] ?? 'attachment',
                    'fileType' => $attachment['fileType'] ?? 'application/octet-stream',
                    'kind' => $attachment['kind'] ?? 'proof',
                    'notes' => $attachment['notes'] ?? null,
                    'uploadedAt' => $attachment['uploadedAt'] ?? null,
                    'hasData' => trim((string) ($attachment['dataUrl'] ?? '')) !== '',
                ],
                $attachments,
                array_keys($attachments),
            )),
            'attachmentCount' => count($attachments),
            'hasProof' => count($attachments) > 0,
            'auditTrail' => is_array($workOrder->audit_trail) ? $workOrder->audit_trail : [],
            'meta' => $workOrder->meta ?? [],
            'createdAt' => $workOrder->created_at?->toIso8601String(),
            'updatedAt' => $workOrder->updated_at?->toIso8601String(),
        ];
    }

    private function workOrderStatusLabel(string $status): string
    {
        return match ($this->normalizeWorkOrderStatus($status)) {
            'assigned' => 'Assigned',
            'in_progress' => 'In Progress',
            'waiting_parts' => 'Waiting Parts',
            'completed' => 'Completed',
            'verified' => 'Verified',
            'voided' => 'Voided',
            default => 'Open',
        };
    }

    private function workOrderSourceLabel(string $sourceType): string
    {
        return match ($this->normalizeWorkOrderSource($sourceType)) {
            'geotab_fault' => 'From GeoTab Fault',
            'geotab_dvir' => 'From DVIR',
            'geotab_status' => 'From Device Status',
            'service_threshold' => 'Service Threshold',
            default => 'Manual',
        };
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function loadMaintenanceWorkOrders(array $filters = []): array
    {
        if (! $this->maintenanceWorkOrderTableAvailable()) {
            return [];
        }

        $query = MaintenanceWorkOrder::query();
        $vehicle = $this->sanitizeText($filters['vehicle'] ?? '', '');
        if ($vehicle !== '') {
            $query->where(function ($builder) use ($vehicle): void {
                $builder->where('vehicle_plate', $vehicle)
                    ->orWhere('vehicle_geotab_id', $vehicle);
            });
        }
        $status = $this->sanitizeText($filters['status'] ?? '', '');
        if ($status !== '') {
            $query->where('status', $this->normalizeWorkOrderStatus($status));
        }

        return array_values(array_map(
            fn (MaintenanceWorkOrder $workOrder): array => $this->formatMaintenanceWorkOrder($workOrder),
            $query->orderByDesc('updated_at')->orderByDesc('id')->get()->all(),
        ));
    }

    /**
     * @param  array<int, array<string, mixed>>  $derived
     * @return array<int, array<string, mixed>>
     */
    private function mergeNativeMaintenanceWorkOrders(array $derived): array
    {
        $native = $this->loadMaintenanceWorkOrders();
        $nativeSourceKeys = [];
        foreach ($native as $row) {
            $key = $this->maintenanceWorkOrderSourceKey($row);
            if ($key !== null) {
                $nativeSourceKeys[$key] = true;
            }
        }

        $rows = $native;
        foreach ($derived as $row) {
            $key = $this->maintenanceWorkOrderSourceKey($row);
            if ($key !== null && isset($nativeSourceKeys[$key])) {
                continue;
            }
            $rows[] = $row;
        }

        usort($rows, function (array $a, array $b): int {
            $statusRank = [
                'open' => 0,
                'assigned' => 1,
                'in_progress' => 2,
                'waiting_parts' => 3,
                'completed' => 4,
                'verified' => 5,
                'voided' => 6,
            ];
            $priorityRank = ['critical' => 0, 'high' => 1, 'medium' => 2, 'low' => 3];
            $aStatus = $statusRank[$this->normalizeWorkOrderStatus((string) ($a['status'] ?? 'open'))] ?? 10;
            $bStatus = $statusRank[$this->normalizeWorkOrderStatus((string) ($b['status'] ?? 'open'))] ?? 10;
            if ($aStatus !== $bStatus) {
                return $aStatus <=> $bStatus;
            }

            $aPriority = $priorityRank[$this->normalizeWorkOrderPriority((string) ($a['priorityKey'] ?? $a['priority'] ?? 'medium'))] ?? 10;
            $bPriority = $priorityRank[$this->normalizeWorkOrderPriority((string) ($b['priorityKey'] ?? $b['priority'] ?? 'medium'))] ?? 10;
            if ($aPriority !== $bPriority) {
                return $aPriority <=> $bPriority;
            }

            return strcmp((string) ($b['updatedAt'] ?? $b['scheduledDate'] ?? ''), (string) ($a['updatedAt'] ?? $a['scheduledDate'] ?? ''));
        });

        return array_values($rows);
    }

    /**
     * @param  array<string, mixed>  $row
     */
    private function maintenanceWorkOrderSourceKey(array $row): ?string
    {
        $sourceType = $this->normalizeWorkOrderSource((string) ($row['sourceType'] ?? 'manual'));
        $sourceRecordId = trim((string) ($row['sourceRecordId'] ?? ''));
        if ($sourceType === 'manual' || $sourceRecordId === '') {
            return null;
        }

        return $sourceType.'|'.$sourceRecordId;
    }

    /**
     * @param  array<int, array<string, mixed>>  $vehicles
     * @param  array<int, array<string, mixed>>  $workOrders
     * @return array<int, array<string, mixed>>
     */
    private function attachMaintenanceWorkOrdersToVehicles(array $vehicles, array $workOrders): array
    {
        return array_values(array_map(function (array $vehicle) use ($workOrders): array {
            $plate = strtolower(trim((string) ($vehicle['plate'] ?? '')));
            $geotabId = strtolower(trim((string) ($vehicle['geotabId'] ?? '')));
            $related = array_values(array_filter($workOrders, function (array $workOrder) use ($plate, $geotabId): bool {
                $workOrderPlate = strtolower(trim((string) ($workOrder['vehiclePlate'] ?? $workOrder['vehicle'] ?? '')));
                $workOrderGeotabId = strtolower(trim((string) ($workOrder['vehicleGeotabId'] ?? '')));

                return ($plate !== '' && $workOrderPlate === $plate)
                    || ($geotabId !== '' && $workOrderGeotabId === $geotabId);
            }));

            $open = array_values(array_filter(
                $related,
                fn (array $row): bool => ! in_array($this->normalizeWorkOrderStatus((string) ($row['status'] ?? 'open')), ['completed', 'verified', 'voided'], true),
            ));
            $completed = array_values(array_filter(
                $related,
                fn (array $row): bool => in_array($this->normalizeWorkOrderStatus((string) ($row['status'] ?? 'open')), ['completed', 'verified'], true),
            ));

            $vehicle['workOrders'] = array_slice($related, 0, 8);
            $vehicle['openWorkOrders'] = array_slice($open, 0, 5);
            $vehicle['latestCompletedWorkOrder'] = $completed[0] ?? null;

            return $vehicle;
        }, $vehicles));
    }

    private function loadMaintenanceHistory(array $filters = []): array
    {
        if (! $this->maintenanceHistoryTableAvailable()) {
            return [];
        }

        $query = MaintenanceHistory::query();
        $vehicle = $this->sanitizeText($filters['vehicle'] ?? '', '');
        if ($vehicle !== '') {
            $query->where(function ($builder) use ($vehicle): void {
                $builder->where('vehicle_plate', $vehicle)
                    ->orWhere('vehicle_geotab_id', $vehicle);
            });
        }
        $type = $this->sanitizeText($filters['type'] ?? '', '');
        if ($type !== '') {
            $query->where('type', $type);
        }
        $dateFrom = $this->parseDate($filters['dateFrom'] ?? null);
        if ($dateFrom !== null) {
            $query->where('recorded_at', '>=', $dateFrom->startOfDay());
        }
        $dateTo = $this->parseDate($filters['dateTo'] ?? null);
        if ($dateTo !== null) {
            $query->where('recorded_at', '<=', $dateTo->endOfDay());
        }

        return array_values(array_map(
            fn (MaintenanceHistory $history): array => $this->formatMaintenanceHistory($history),
            $query->orderByDesc('recorded_at')->orderByDesc('id')->get()->all(),
        ));
    }

    private function formatMaintenanceHistory(MaintenanceHistory $history): array
    {
        return [
            'id' => (string) $history->id,
            'source' => $history->source ?: data_get($history->meta, 'source', 'manual'),
            'isManual' => ($history->source ?: data_get($history->meta, 'source', 'manual')) === 'manual',
            'isReadOnly' => ($history->source ?: data_get($history->meta, 'source', 'manual')) !== 'manual',
            'vehicleGeotabId' => $history->vehicle_geotab_id,
            'vehiclePlate' => $history->vehicle_plate ?: 'N/A',
            'vehicle' => $history->vehicle_plate ?: 'N/A',
            'type' => $history->type,
            'description' => $history->description,
            'status' => $history->status ?: 'recorded',
            'voided' => ($history->status ?? '') === 'voided',
            'voidedAt' => $history->voided_at?->toIso8601String(),
            'voidReason' => $history->void_reason,
            'date' => $this->displayDate($history->recorded_at),
            'displayDate' => $this->displayDate($history->recorded_at),
            'dateTime' => $history->recorded_at?->toIso8601String(),
            'recordedAt' => $history->recorded_at?->toIso8601String(),
            'nextDueAt' => $history->next_due_at?->toIso8601String(),
            'nextDueLabel' => $this->displayShortDate($history->next_due_at),
            'odometerKm' => $history->odometer_km !== null ? (float) $history->odometer_km : null,
            'cost' => $history->cost !== null ? (float) $history->cost : null,
            'costLabel' => $history->cost !== null ? $this->money((float) $history->cost) : 'N/A',
            'provider' => $history->provider ?: 'N/A',
            'notes' => $history->notes ?: 'N/A',
            'proofFileName' => $history->proof_file_name,
            'proofFileType' => $history->proof_file_type,
            'hasProof' => trim((string) $history->proof_file_name) !== '',
            'syncStatus' => $history->sync_status ?? data_get($history->meta, 'syncStatus', 'not_staged'),
            'syncLabel' => $this->geotabSyncLabel($history->sync_status ?? data_get($history->meta, 'syncStatus', 'not_staged')),
            'hasLocalGeotabChanges' => ($history->sync_status ?? data_get($history->meta, 'syncStatus', 'not_staged')) === 'local_modified',
            'canPushToGeotab' => ($history->sync_status ?? data_get($history->meta, 'syncStatus', 'not_staged')) === 'local_modified',
            'syncError' => $history->sync_error,
            'pendingWriteJobId' => $history->pending_write_job_id,
            'geotabSnapshot' => $history->geotab_snapshot,
            'meta' => $history->meta ?? [],
        ];
    }

    private function stageMaintenanceReminderWriteBack(MaintenanceHistory $history, string $createdBy = 'system'): void
    {
        if (! $this->writeBack->tableAvailable() || trim((string) $history->vehicle_geotab_id) === '' || $history->next_due_at === null) {
            return;
        }

        $job = $this->writeBack->createJob(
            'maintenance.reminder',
            'ReminderRule',
            $this->maintenanceWriteBackPayload($history),
            'maintenance_history',
            (string) $history->id,
            'maintenance-reminder-'.$history->id.'-'.$history->next_due_at->timestamp,
            $createdBy,
            $this->buildGeotabPreviewPayload('Maintenance Reminder', (string) ($history->vehicle_plate ?: $history->vehicle_geotab_id), $this->maintenanceWriteBackPayload($history), $history->geotab_snapshot ?? null),
        );
        if ($job !== null) {
            $history->forceFill([
                'sync_status' => 'pending_approval',
                'pending_write_job_id' => $job->id,
                'sync_error' => null,
            ])->saveQuietly();
        }
    }

    private function maintenanceWriteBackPayload(MaintenanceHistory $history): array
    {
        return [
            'entity' => [
                'name' => 'PioneerPath '.$history->type.' - '.($history->vehicle_plate ?: $history->vehicle_geotab_id),
                'device' => ['id' => $history->vehicle_geotab_id],
                'date' => $history->next_due_at?->toIso8601String(),
                'comment' => $history->description,
            ],
        ];
    }

    private function markMaintenanceGeotabDirty(MaintenanceHistory $history): void
    {
        if (trim((string) $history->vehicle_geotab_id) === '' || $history->next_due_at === null) {
            $history->forceFill([
                'sync_status' => 'not_staged',
                'sync_error' => null,
                'pending_write_job_id' => null,
            ])->saveQuietly();

            return;
        }

        $payload = $this->maintenanceWriteBackPayload($history);
        $history->forceFill([
            'sync_status' => $this->payloadMatchesGeotabSnapshot($payload, $history->geotab_snapshot ?? null) ? 'synced' : 'local_modified',
            'sync_error' => null,
            'pending_write_job_id' => null,
        ])->saveQuietly();
    }

    public function pushMaintenanceHistoryToGeotab(Request $request, string $historyId): JsonResponse
    {
        if (! $this->maintenanceHistoryTableAvailable()) {
            return $this->respondError('Maintenance history table is not available.', 503);
        }

        $history = MaintenanceHistory::query()->find($historyId);
        if ($history === null) {
            return $this->respondError('Maintenance record not found.', 404);
        }
        if (trim((string) $history->vehicle_geotab_id) === '' || $history->next_due_at === null) {
            return $this->respondError('A GeoTab Device ID and next due date are required before pushing a maintenance reminder.', 422);
        }

        $payload = $this->maintenanceWriteBackPayload($history);
        if ($this->payloadMatchesGeotabSnapshot($payload, $history->geotab_snapshot ?? null)) {
            return $this->respondData([
                ...$this->formatMaintenanceHistory($history),
                'geotabAlreadyUpToDate' => true,
                'message' => 'GeoTab is already up to date.',
            ]);
        }
        if ($this->isGeotabPreviewRequest($request)) {
            return $this->respondData([
                ...$this->formatMaintenanceHistory($history),
                ...$this->pendingGeotabPushMetadata('maintenance_history', (string) $history->id),
                'message' => 'Review this GeoTab payload before staging it for approval.',
                'previewOnly' => true,
                'preview' => $payload,
                'previewPayload' => $this->buildGeotabPreviewPayload('Maintenance Reminder', (string) ($history->vehicle_plate ?: $history->vehicle_geotab_id), $payload, $history->geotab_snapshot ?? null),
            ]);
        }

        $this->stageMaintenanceReminderWriteBack($history, $this->geotabActorFromRequest($request));
        $this->clearFleetCaches();

        return $this->respondData([
            ...$this->formatMaintenanceHistory($history->refresh()),
            'message' => 'GeoTab push request staged for admin approval.',
            'preview' => $payload,
        ]);
    }

    private function mergeMaintenanceHistory(array $maintenance, array $vehicles): array
    {
        $history = $this->loadMaintenanceHistory();
        if ($history === []) {
            return $maintenance;
        }

        $platesByGeotabId = [];
        foreach ($vehicles as $vehicle) {
            $deviceId = (string) ($vehicle['geotabId'] ?? '');
            if ($deviceId !== '') {
                $platesByGeotabId[$deviceId] = (string) ($vehicle['plate'] ?? '');
            }
        }

        foreach ($history as $row) {
            $vehiclePlate = trim((string) ($row['vehiclePlate'] ?? ''));
            $vehicleId = trim((string) ($row['vehicleGeotabId'] ?? ''));
            if ($vehiclePlate === '' && $vehicleId !== '' && isset($platesByGeotabId[$vehicleId])) {
                $vehiclePlate = $platesByGeotabId[$vehicleId];
            }

            $maintenance[] = [
                'vehicle' => $vehiclePlate !== '' ? $vehiclePlate : 'N/A',
                'type' => $row['type'] ?? 'Maintenance',
                'description' => $row['description'] ?? 'Manual maintenance record',
                'status' => $row['status'] ?? 'recorded',
                'date' => $row['date'] ?? 'N/A',
                'dateTime' => $row['dateTime'] ?? null,
                'provider' => $row['provider'] ?? 'N/A',
                'nextDue' => $row['nextDueLabel'] ?? 'N/A',
                'source' => 'manual',
            ];
        }

        usort($maintenance, fn (array $a, array $b) => strcmp((string) ($b['dateTime'] ?? ''), (string) ($a['dateTime'] ?? '')));

        return $maintenance;
    }

    private function loadNotificationPreferences(): array
    {
        $defaults = $this->defaultNotificationPreferences();

        if (! $this->notificationPreferencesTableAvailable()) {
            $cached = Cache::get('pioneer_notification_preferences_fallback', []);

            return is_array($cached) && $cached !== [] ? [...$defaults, ...$cached] : $defaults;
        }

        $preference = NotificationPreference::query()->firstOrCreate(
            ['scope' => 'global', 'scope_key' => 'default'],
            [
                'browser_enabled' => $defaults['browserEnabled'],
                'email_enabled' => $defaults['emailEnabled'],
                'trip_alerts' => $defaults['tripAlerts'],
                'maintenance_alerts' => $defaults['maintenanceAlerts'],
                'billing_alerts' => $defaults['billingAlerts'],
                'system_alerts' => $defaults['systemAlerts'],
                'quiet_hours' => $defaults['quietHours'],
            ],
        );

        return $this->formatNotificationPreferences($preference);
    }

    private function defaultNotificationPreferences(): array
    {
        return [
            'scope' => 'global',
            'scopeKey' => 'default',
            'browserEnabled' => true,
            'emailEnabled' => false,
            'tripAlerts' => true,
            'maintenanceAlerts' => true,
            'billingAlerts' => true,
            'systemAlerts' => true,
            'quietHours' => ['start' => '22:00', 'end' => '06:00'],
            'meta' => [],
        ];
    }

    private function formatNotificationPreferences(NotificationPreference $preference): array
    {
        return [
            'id' => (string) $preference->id,
            'scope' => $preference->scope,
            'scopeKey' => $preference->scope_key,
            'browserEnabled' => (bool) $preference->browser_enabled,
            'emailEnabled' => (bool) $preference->email_enabled,
            'tripAlerts' => (bool) $preference->trip_alerts,
            'maintenanceAlerts' => (bool) $preference->maintenance_alerts,
            'billingAlerts' => (bool) $preference->billing_alerts,
            'systemAlerts' => (bool) $preference->system_alerts,
            'quietHours' => $preference->quiet_hours ?? ['start' => '22:00', 'end' => '06:00'],
            'meta' => $preference->meta ?? [],
        ];
    }

    private function loadClientAssignments(): array
    {
        if (! $this->clientAssignmentsTableAvailable()) {
            return [];
        }

        return array_values(array_map(
            fn (ClientVehicleAssignment $assignment): array => $this->formatClientAssignment($assignment),
            ClientVehicleAssignment::query()->orderByDesc('updated_at')->orderByDesc('id')->get()->all(),
        ));
    }

    private function formatClientAssignment(ClientVehicleAssignment $assignment): array
    {
        return [
            'id' => (string) $assignment->id,
            'clientName' => $assignment->client_name,
            'clientEmail' => $assignment->client_email ?: 'N/A',
            'clientPhone' => $assignment->client_phone ?: 'N/A',
            'vehicleGeotabId' => $assignment->vehicle_geotab_id,
            'vehiclePlate' => $assignment->vehicle_plate ?: 'N/A',
            'tripId' => $assignment->trip_id,
            'status' => $assignment->status ?: 'active',
            'notes' => $assignment->notes ?: 'N/A',
            'meta' => $assignment->meta ?? [],
            'updatedAt' => $assignment->updated_at?->toIso8601String(),
        ];
    }

    private function clientAssignmentFor(array $trip, ?array $vehicle): ?array
    {
        $assignments = $this->loadClientAssignments();
        if ($assignments === []) {
            return null;
        }

        $tripId = (string) ($trip['tripId'] ?? '');
        $vehicleId = (string) ($vehicle['geotabId'] ?? '');
        $vehiclePlate = strtolower(trim((string) ($vehicle['plate'] ?? $trip['vehicle'] ?? '')));

        foreach ($assignments as $assignment) {
            if ($tripId !== '' && (string) ($assignment['tripId'] ?? '') === $tripId) {
                return $assignment;
            }

            if ($vehicleId !== '' && (string) ($assignment['vehicleGeotabId'] ?? '') === $vehicleId) {
                return $assignment;
            }

            if ($vehiclePlate !== '' && strtolower(trim((string) ($assignment['vehiclePlate'] ?? ''))) === $vehiclePlate) {
                return $assignment;
            }
        }

        return null;
    }

    private function maskedDriverContactForClientTracking(string $driverName): ?string
    {
        $name = trim($driverName);
        if ($name === '' || ! $this->manualDriversTableAvailable()) {
            return null;
        }

        $phone = ManualDriver::query()
            ->whereRaw('LOWER(name) = ?', [Str::lower($name)])
            ->value('phone');
        $digits = preg_replace('/\D+/', '', (string) $phone) ?? '';

        if (strlen($digits) < 4) {
            return null;
        }

        return '09XX XXX '.substr($digits, -4);
    }

    private function maybeStoreMaintenanceDueNotification(MaintenanceHistory $history): void
    {
        $status = strtolower(trim((string) $history->status));
        $warningDays = max(0, (int) $this->systemSettingsValue('maintenance_due_warning_days', 14));
        $isDue = ($history->next_due_at !== null && $history->next_due_at->lte(now()->addDays($warningDays)))
            || str_contains($status, 'due')
            || str_contains($status, 'overdue');

        if (! $isDue) {
            return;
        }

        $vehicle = $history->vehicle_plate ?: 'Vehicle';
        $dueLabel = $history->next_due_at?->toDateString() ?? 'now';

        $this->storeOperationalNotification(
            'maintenance-due-'.$history->id,
            'maintenance',
            'Maintenance Due',
            $vehicle.' has maintenance due '.$dueLabel.'.',
            [
                'historyId' => $history->id,
                'vehiclePlate' => $history->vehicle_plate,
                'url' => '/maintenance',
                'tag' => 'maintenance-due-'.$history->id,
            ],
        );
    }

    private function storeHumidityBreachNotificationsFromFeedRows(): void
    {
        if (! $this->notificationHistoryTableAvailable() || ! Schema::hasTable('geotab_feed_rows')) {
            return;
        }

        $weekStart = now()->startOfWeek();
        $weekEnd = now()->endOfWeek();

        GeotabFeedRow::query()
            ->where('type_name', 'StatusData')
            ->whereBetween('recorded_at', [$weekStart, $weekEnd])
            ->orderBy('recorded_at')
            ->limit(100)
            ->get()
            ->filter(fn (GeotabFeedRow $row): bool => $this->isHumidityBreachFeedRow($row))
            ->each(function (GeotabFeedRow $row): void {
                $deviceId = trim((string) ($row->device_geotab_id ?: 'unknown-device'));
                $dateKey = ($row->recorded_at ?? now())->format('Ymd');
                $value = $this->humidityValueFromFeedRow($row);
                $valueLabel = $value === null ? 'outside the configured threshold' : number_format($value, 1).'%';

                $this->storeOperationalNotification(
                    'humidity-breach-'.$deviceId.'-'.$dateKey,
                    'alert',
                    'Humidity Threshold Breached',
                    'Vehicle '.$deviceId.' reported humidity '.$valueLabel.'.',
                    [
                        'deviceGeotabId' => $deviceId,
                        'feedRowId' => $row->id,
                        'humidity' => $value,
                        'url' => '/analytics',
                        'tag' => 'humidity-breach-'.$deviceId.'-'.$dateKey,
                    ],
                );
            });
    }

    private function isHumidityBreachFeedRow(GeotabFeedRow $row): bool
    {
        $payload = is_array($row->payload) ? $row->payload : [];
        if (
            data_get($payload, 'alert_triggered') === true
            || data_get($payload, 'alertTriggered') === true
            || data_get($payload, 'alerts.humidityAlert') === true
        ) {
            return true;
        }

        if ($row->diagnostic_alias !== 'relativeHumidity') {
            return false;
        }

        $value = $this->humidityValueFromFeedRow($row);

        return $value !== null && ($value < 25 || $value > 75);
    }

    private function humidityValueFromFeedRow(GeotabFeedRow $row): ?float
    {
        $payload = is_array($row->payload) ? $row->payload : [];
        $value = data_get($payload, 'data', data_get($payload, 'value', data_get($payload, 'displayValue')));

        return is_numeric($value) ? (float) $value : null;
    }

    private function storeOperationalNotification(string $notificationId, string $category, string $title, string $message, array $payload = []): void
    {
        if (! $this->notificationHistoryTableAvailable()) {
            return;
        }

        $payload = [
            'url' => $payload['url'] ?? $this->notificationUrlForCategory($category, $payload),
            'icon' => $payload['icon'] ?? '/icons/Icon-192.png',
            'tag' => $payload['tag'] ?? $notificationId,
            ...$payload,
        ];

        $existing = NotificationHistory::query()
            ->where('notification_id', $notificationId)
            ->first();

        if ($existing !== null) {
            $existing->forceFill([
                'title' => $title,
                'message' => $message,
                'category' => $category,
                'payload' => $payload,
            ])->save();

            return;
        }

        $notification = NotificationHistory::query()->create([
            'notification_id' => $notificationId,
            'title' => $title,
            'message' => $message,
            'category' => $category,
            'status' => 'sent',
            'audience' => 'internal',
            'payload' => $payload,
            'delivered_at' => now(),
        ]);

        $this->queuePushNotification($notification);
        $this->queueCriticalEmailForNotification($notification);
    }

    private function storeCustomNotification(string $category, string $title, string $message, array $payload = []): void
    {
        if (! $this->notificationHistoryTableAvailable()) {
            return;
        }

        $payload = [
            'url' => $payload['url'] ?? $this->notificationUrlForCategory($category, $payload),
            'icon' => $payload['icon'] ?? '/icons/Icon-192.png',
            'tag' => $payload['tag'] ?? Str::slug($category.'-'.$title),
            ...$payload,
        ];

        $notification = NotificationHistory::query()->create([
            'notification_id' => 'custom-'.Str::lower(Str::random(18)),
            'title' => $title,
            'message' => $message,
            'category' => $category,
            'status' => 'sent',
            'audience' => 'internal',
            'payload' => $payload,
            'delivered_at' => now(),
        ]);

        $this->queuePushNotification($notification);
        $this->queueCriticalEmailForNotification($notification);
    }

    private function queueCriticalEmailForNotification(NotificationHistory $notification): void
    {
        $payload = is_array($notification->payload) ? $notification->payload : [];
        $category = strtolower((string) $notification->category);
        $tag = strtolower((string) ($payload['tag'] ?? $notification->notification_id ?? ''));
        $recipients = [];

        if ($category === 'alert' && str_contains($tag, 'humidity-breach')) {
            $recipients = [
                ...$this->emailsForManagedRoles(['fleet_manager']),
                ...$this->assignedDriverEmailsForPayload($payload),
            ];
        } elseif (($category === 'vehicle' || $category === 'maintenance') && str_contains($tag, 'expiry')) {
            $recipients = $this->emailsForManagedRoles(['fleet_manager']);
        } elseif ($category === 'maintenance' && (str_contains($tag, 'maintenance-due') || str_contains(strtolower((string) $notification->title), 'maintenance'))) {
            $recipients = $this->emailsForManagedRoles(['fleet_manager']);
        } elseif ($category === 'system' && (str_contains($tag, 'writeback') || str_contains($tag, 'backup'))) {
            $recipients = $this->emailsForManagedRoles(['super_administrator']);
        }

        $recipients = array_values(array_unique(array_filter($recipients)));
        if ($recipients === []) {
            return;
        }

        SendCriticalNotificationEmail::dispatch(
            $recipients,
            '[PioneerPath] '.$notification->title,
            $notification->message."\n\nOpen PioneerPath: ".(string) ($payload['url'] ?? '/notifications'),
            [
                'notificationId' => $notification->notification_id,
                'category' => $notification->category,
            ],
        );
    }

    /**
     * @param  array<int, string>  $roles
     * @return array<int, string>
     */
    private function emailsForManagedRoles(array $roles): array
    {
        if (! Schema::hasTable('users')) {
            return [];
        }

        return User::query()
            ->whereIn('role', $roles)
            ->where('status', 'active')
            ->pluck('email')
            ->filter()
            ->map(fn (mixed $email): string => strtolower(trim((string) $email)))
            ->filter(fn (string $email): bool => filter_var($email, FILTER_VALIDATE_EMAIL) !== false)
            ->values()
            ->all();
    }

    /**
     * @param  array<string, mixed>  $payload
     * @return array<int, string>
     */
    private function assignedDriverEmailsForPayload(array $payload): array
    {
        $emails = [];
        $driverEmail = strtolower(trim((string) ($payload['driverEmail'] ?? '')));
        if (filter_var($driverEmail, FILTER_VALIDATE_EMAIL) !== false) {
            $emails[] = $driverEmail;
        }

        $deviceId = strtolower(trim((string) ($payload['deviceGeotabId'] ?? $payload['vehicleGeotabId'] ?? '')));
        if ($deviceId !== '' && Schema::hasTable('client_vehicle_assignments')) {
            $assignment = ClientVehicleAssignment::query()
                ->whereRaw('lower(vehicle_geotab_id) = ?', [$deviceId])
                ->latest('updated_at')
                ->first();
            $assignmentEmail = strtolower(trim((string) data_get($assignment?->meta, 'driverEmail', '')));
            if (filter_var($assignmentEmail, FILTER_VALIDATE_EMAIL) !== false) {
                $emails[] = $assignmentEmail;
            }
        }

        if ($emails === [] && Schema::hasTable('users')) {
            $emails = $this->emailsForManagedRoles(['driver']);
        }

        return $emails;
    }

    private function notificationUrlForCategory(string $category, array $payload): string
    {
        $tripId = trim((string) ($payload['tripId'] ?? ''));

        return match ($category) {
            'trip', 'dispatch' => $tripId !== '' ? '/trips?tripId='.$tripId : '/trips',
            'maintenance' => '/maintenance',
            'fuel' => '/delivery-confirm',
            'billing' => '/billing',
            'driver' => '/drivers',
            'alert' => '/notifications?filter=alerts',
            default => '/notifications',
        };
    }

    private function queuePushNotification(NotificationHistory $notification): void
    {
        if (! Schema::hasTable('push_subscriptions')) {
            return;
        }

        $count = PushSubscription::query()->count();
        if ($count === 0) {
            return;
        }

        try {
            $summary = $this->pushSender->send($notification);
        } catch (\Throwable $e) {
            $summary = [
                'status' => 'failed',
                'reason' => $e->getMessage(),
            ];
            Log::channel('app_errors')->warning('PioneerPath push notification failed without blocking notification storage', [
                'notificationId' => $notification->notification_id,
                'errorType' => get_class($e),
                'errorMessage' => $e->getMessage(),
            ]);
        }

        Log::channel('notifications')->info('PioneerPath push notification processed', [
            'notificationId' => $notification->notification_id,
            'subscriptions' => $count,
            'category' => $notification->category,
            'webPush' => $summary,
        ]);
    }

    private function mergeStoredNotifications(array $notifications): array
    {
        if (! $this->notificationHistoryTableAvailable()) {
            return $notifications;
        }

        $existing = [];
        foreach ($notifications as $notification) {
            $id = (string) ($notification['id'] ?? '');
            if ($id !== '') {
                $existing[$id] = true;
            }
        }

        $history = NotificationHistory::query()->latest('delivered_at')->latest('id')->limit(25)->get();
        foreach ($history as $row) {
            $notificationId = $row->notification_id ?: 'history-'.$row->id;
            if (isset($existing[$notificationId])) {
                continue;
            }

            $notifications[] = [
                'id' => $notificationId,
                'title' => $row->title,
                'message' => $row->message,
                'time' => $this->displayDate($row->delivered_at),
                'timestamp' => $row->delivered_at?->toIso8601String() ?? $row->created_at?->toIso8601String(),
                'category' => $row->category,
                'isRead' => $row->read_at !== null,
                'source' => 'history',
            ];
        }

        usort($notifications, fn (array $a, array $b) => strcmp((string) ($b['timestamp'] ?? ''), (string) ($a['timestamp'] ?? '')));

        return $notifications;
    }

    private function manualDriversTableAvailable(): bool
    {
        return $this->tableAvailable('manual_drivers');
    }

    private function manualVehiclesTableAvailable(): bool
    {
        return $this->tableAvailable('manual_vehicles');
    }

    private function maintenanceHistoryTableAvailable(): bool
    {
        return $this->tableAvailable('maintenance_histories');
    }

    private function maintenanceWorkOrderTableAvailable(): bool
    {
        return $this->tableAvailable('maintenance_work_orders');
    }

    private function fuelEventTableAvailable(): bool
    {
        return $this->tableAvailable('fuel_events');
    }

    private function notificationPreferencesTableAvailable(): bool
    {
        return $this->tableAvailable('notification_preferences');
    }

    private function notificationHistoryTableAvailable(): bool
    {
        return $this->tableAvailable('notification_histories');
    }

    private function clientAssignmentsTableAvailable(): bool
    {
        return $this->tableAvailable('client_vehicle_assignments');
    }

    private function fleetClientsTableAvailable(): bool
    {
        return $this->tableAvailable('fleet_clients');
    }

    private function billingInvoiceReferencesTableAvailable(): bool
    {
        return $this->tableAvailable('billing_invoice_references');
    }

    private function tableAvailable(string $table): bool
    {
        try {
            return Schema::hasTable($table);
        } catch (\Throwable) {
            return false;
        }
    }

    private function storeNotificationState(array $state): void
    {
        Cache::put('geotab_notification_state_v1', [
            'read' => $state['read'] ?? [],
            'deleted' => $state['deleted'] ?? [],
        ], now()->addDays(14));
    }

    private function applyNotificationState(array $notifications): array
    {
        $state = $this->notificationState();
        $read = $state['read'] ?? [];
        $deleted = $state['deleted'] ?? [];

        $filtered = array_values(array_filter($notifications, function (array $notification) use ($deleted): bool {
            $id = (string) ($notification['id'] ?? '');
            $source = strtolower((string) ($notification['source'] ?? ''));
            if ($source === 'history') {
                return true;
            }

            return $id === '' || ! isset($deleted[$id]);
        }));

        return array_values(array_map(function (array $notification) use ($read): array {
            $id = (string) ($notification['id'] ?? '');
            if ($id !== '' && isset($read[$id])) {
                $notification['isRead'] = true;
            }

            return $notification;
        }, $filtered));
    }

    private function trackingProgress(string $status): int
    {
        return match (strtolower(trim($status))) {
            'completed' => 100,
            'dispatched', 'in progress', 'on trip' => 65,
            default => 15,
        };
    }

    private function loadPod(string $tripId): ?array
    {
        if (! $this->podTableAvailable()) {
            return null;
        }

        $pod = ProofOfDelivery::query()->where('trip_id', $tripId)->latest('updated_at')->first();

        return $pod !== null ? $this->formatPod($pod) : null;
    }

    private function formatPod(ProofOfDelivery $pod): array
    {
        return [
            'tripId' => $pod->trip_id,
            'trackingToken' => $pod->tracking_token,
            'recipientName' => $pod->recipient_name,
            'notes' => $pod->notes,
            'status' => $pod->status,
            'deliveredAt' => $pod->delivered_at?->toIso8601String(),
            'hasSignature' => filled($pod->signature_data_url),
            'attachments' => $this->formatPodAttachments((array) ($pod->attachments ?? []), $pod->trip_id),
            'meta' => $pod->meta ?? [],
        ];
    }

    private function formatPodAttachments(array $attachments, string $tripId): array
    {
        return array_values(array_filter(array_map(function (mixed $attachment, int|string $index) use ($tripId): ?array {
            $path = $this->podAttachmentPath($attachment);

            if (is_string($attachment)) {
                return [
                    'path' => $path,
                    'name' => basename($path),
                    'url' => url('/api/fleet/pod/'.$tripId.'/attachments/'.$index),
                ];
            }

            if (! is_array($attachment)) {
                return null;
            }

            $name = $this->sanitizeText($attachment['name'] ?? $attachment['fileName'] ?? basename($path), 'Attachment');
            $formatted = [
                'path' => $path,
                'name' => $name,
                'type' => $this->sanitizeText($attachment['type'] ?? $attachment['fileType'] ?? '', ''),
                'demo' => (bool) ($attachment['demo'] ?? false),
            ];

            if ($path !== '') {
                $formatted['url'] = url('/api/fleet/pod/'.$tripId.'/attachments/'.$index);
            }

            return array_filter($formatted, fn (mixed $value): bool => $value !== null && $value !== '');
        }, $attachments, array_keys($attachments))));
    }

    private function podAttachmentPath(mixed $attachment): string
    {
        if (is_string($attachment)) {
            return trim($attachment);
        }

        if (! is_array($attachment)) {
            return '';
        }

        foreach (['path', 'storagePath', 'filePath'] as $key) {
            if (isset($attachment[$key]) && is_string($attachment[$key])) {
                return trim($attachment[$key]);
            }
        }

        return '';
    }

    private function podTableAvailable(): bool
    {
        try {
            return Schema::hasTable('proof_of_deliveries');
        } catch (\Throwable) {
            return false;
        }
    }

    private function validateUploadedProofFile(UploadedFile $file): void
    {
        $mime = $this->detectFileMimeType($file->getRealPath() ?: '');
        if (! in_array($mime, $this->allowedProofMimeTypes(), true)) {
            throw ValidationException::withMessages([
                'attachments' => 'Proof uploads must be JPEG, PNG, or PDF files.',
            ]);
        }

        if ($file->getSize() !== false && $file->getSize() > 10 * 1024 * 1024) {
            throw ValidationException::withMessages([
                'attachments' => 'Proof uploads must be 10MB or smaller.',
            ]);
        }
    }

    private function validateProofDataUrl(mixed $value, string $field, bool $requireDataUrl = false): void
    {
        $raw = trim((string) ($value ?? ''));
        if ($raw === '') {
            return;
        }

        if (strlen($raw) > 14_000_000) {
            throw ValidationException::withMessages([
                $field => 'Proof data must be 10MB or smaller.',
            ]);
        }

        if (! preg_match('/^data:([^;]+);base64,(.+)$/', $raw, $matches)) {
            if ($requireDataUrl) {
                throw ValidationException::withMessages([
                    $field => 'Proof data must be an uploaded JPEG, PNG, or PDF payload.',
                ]);
            }

            return;
        }

        $decoded = base64_decode($matches[2], true);
        if ($decoded === false || strlen($decoded) > 10 * 1024 * 1024) {
            throw ValidationException::withMessages([
                $field => 'Proof data must be 10MB or smaller.',
            ]);
        }

        $tmp = tempnam(sys_get_temp_dir(), 'pioneer-proof-');
        if ($tmp === false) {
            throw ValidationException::withMessages([
                $field => 'Proof data could not be validated.',
            ]);
        }

        try {
            file_put_contents($tmp, $decoded);
            $mime = $this->detectFileMimeType($tmp);
        } finally {
            @unlink($tmp);
        }

        if (! in_array($mime, $this->allowedProofMimeTypes(), true)) {
            throw ValidationException::withMessages([
                $field => 'Proof data must be JPEG, PNG, or PDF.',
            ]);
        }
    }

    /**
     * @return array<int, string>
     */
    private function allowedProofMimeTypes(): array
    {
        return ['image/jpeg', 'image/png', 'application/pdf'];
    }

    private function detectFileMimeType(string $path): string
    {
        if ($path === '' || ! is_file($path)) {
            return 'application/octet-stream';
        }

        $finfo = new \finfo(FILEINFO_MIME_TYPE);

        return (string) ($finfo->file($path) ?: 'application/octet-stream');
    }

    private function findTrip(array $trips, string $tripId): ?array
    {
        foreach ($trips as $trip) {
            if (($trip['tripId'] ?? null) === $tripId || ($trip['geotabId'] ?? null) === $tripId) {
                return $trip;
            }
        }

        return null;
    }

    private function authenticatedRoleFromRequest(Request $request): string
    {
        $role = $request->attributes->get('auth_role');
        if (is_string($role) && trim($role) !== '') {
            return $this->normalizeManagedUserRole($role);
        }

        if (app()->runningUnitTests()) {
            return $this->normalizeManagedUserRole((string) ($request->headers->get('X-Pioneer-Role') ?: 'super_administrator'));
        }

        return '';
    }

    private function maskPersonalLogValue(?string $value): ?string
    {
        $value = trim((string) $value);
        if ($value === '') {
            return null;
        }

        if (str_contains($value, '@')) {
            [$local, $domain] = array_pad(explode('@', $value, 2), 2, '');

            return Str::limit($local, 2, '').'***@'.Str::limit($domain, 2, '').'***';
        }

        return Str::limit($value, 2, '').'***';
    }

    private function passwordResetUrl(string $email, string $plainToken): string
    {
        $frontend = trim((string) config('pioneer.frontend_url', config('app.url', '')));
        if ($frontend === '') {
            $frontend = (string) config('app.url', 'http://localhost');
        }
        $frontend = rtrim($frontend, '/');
        $query = http_build_query([
            'email' => $email,
            'token' => $plainToken,
        ]);

        if (str_contains($frontend, '#')) {
            return $frontend.'/reset-password?'.$query;
        }

        return $frontend.'/#/reset-password?'.$query;
    }

    private function canAccessFleetLocationHistory(Request $request): bool
    {
        return in_array($this->authenticatedRoleFromRequest($request), [
            'super_administrator',
            'system_administrator',
            'fleet_manager',
            'dispatcher',
        ], true);
    }

    private function canAccessTripLocationHistory(Request $request, array $trip): bool
    {
        if ($this->canAccessFleetLocationHistory($request)) {
            return true;
        }

        if ($this->authenticatedRoleFromRequest($request) !== 'driver') {
            return false;
        }

        $user = $request->attributes->get('auth_user');
        $name = strtolower(trim((string) ($user?->name ?? '')));
        $email = strtolower(trim((string) ($user?->email ?? '')));
        $driver = strtolower(trim((string) ($trip['driver'] ?? '')));

        return $driver !== '' && ($driver === $name || $driver === $email);
    }

    /**
     * @param  array<int, array<string, mixed>>  $trips
     * @return array<int, array<string, mixed>>
     */
    private function privacyFilteredTripsForRequest(Request $request, array $trips): array
    {
        if ($this->authenticatedRoleFromRequest($request) === 'driver') {
            $trips = array_values(array_filter(
                $trips,
                fn (array $trip): bool => $this->canAccessTripLocationHistory($request, $trip)
            ));
        }

        return array_values(array_map(
            fn (array $trip): array => $this->privacyFilteredTripForRequest($request, $trip),
            $trips,
        ));
    }

    private function privacyFilteredTripForRequest(Request $request, array $trip): array
    {
        if ($this->authenticatedRoleFromRequest($request) !== 'driver') {
            return $trip;
        }

        foreach (['phone', 'email', 'clientPhone', 'clientEmail', 'customerPhone', 'customerEmail', 'contactNumber', 'contactPersonName', 'billingAddress', 'deliveryAddress'] as $key) {
            if (array_key_exists($key, $trip)) {
                $trip[$key] = 'Hidden for privacy';
            }
        }

        if (is_array($trip['assignment'] ?? null)) {
            foreach (['clientPhone', 'clientEmail', 'clientContact', 'contactNumber', 'email', 'contactPersonName', 'billingAddress', 'deliveryAddress'] as $key) {
                if (array_key_exists($key, $trip['assignment'])) {
                    $trip['assignment'][$key] = 'Hidden for privacy';
                }
            }
        }

        return $trip;
    }

    private function findVehicleForTrip(array $vehicles, array $trip): ?array
    {
        foreach ($vehicles as $vehicle) {
            if (($vehicle['geotabId'] ?? null) === ($trip['deviceGeotabId'] ?? null)) {
                return $vehicle;
            }
            if (($vehicle['geotabId'] ?? null) === ($trip['geotabId'] ?? null)) {
                return $vehicle;
            }
            if (($vehicle['plate'] ?? null) === ($trip['vehicle'] ?? null)) {
                return $vehicle;
            }
        }

        return null;
    }

    private function safeGet(callable $resolver, array $context = [], bool $throwOnTypeMismatch = false): array
    {
        try {
            $result = $resolver();

            return is_array($result) ? $result : [];
        } catch (\Throwable $e) {
            if ($throwOnTypeMismatch && $this->isGeotabEntityTypeMismatch($e)) {
                throw $e;
            }

            $errorKind = $this->classifyThrowable($e);
            $this->markGeotabUnavailable($errorKind);

            if ($errorKind === 'timeout') {
                Log::channel('geotab')->warning('GeoTab request timed out; continuing with cached or empty data.', [
                    ...$context,
                    'errorType' => get_class($e),
                    'errorMessage' => $e->getMessage(),
                ]);
            }

            if ($context !== []) {
                $this->timingLog('safe_get.swallowed', [
                    ...$context,
                    'errorKind' => $errorKind,
                    'errorType' => get_class($e),
                    'errorMessage' => $e->getMessage(),
                ]);
            }

            return [];
        }
    }

    private function isGeotabEntityTypeMismatch(\Throwable $e): bool
    {
        $message = strtolower($e->getMessage());

        return str_contains($message, 'not supported for this operation')
            && str_contains($message, 'please provide an instance of type');
    }

    private function safeDivide(float $numerator, float $denominator): float
    {
        if ($denominator <= 0) {
            return 0.0;
        }

        return round($numerator / $denominator, 2);
    }

    private function respondData(mixed $data): JsonResponse
    {
        $started = defined('LARAVEL_START') ? (float) LARAVEL_START : microtime(true);
        $pagination = null;
        if (is_array($data) && is_array($data['_pagination'] ?? null)) {
            $pagination = $data['_pagination'];
            unset($data['_pagination']);
        } elseif ($this->shouldPaginateResponse($data)) {
            $pagination = $this->paginationPayload($data);
            $data = $pagination['data'];
            unset($pagination['data']);
        }

        $lastSyncedAt = is_array($data) ? ($data['lastSyncedAt'] ?? $data['lastUpdated'] ?? null) : null;
        $snapshotAgeSeconds = null;
        if (is_string($lastSyncedAt) && trim($lastSyncedAt) !== '') {
            try {
                $snapshotAgeSeconds = Carbon::parse($lastSyncedAt)->diffInSeconds(now());
            } catch (\Throwable) {
                $snapshotAgeSeconds = null;
            }
        }

        $payload = [
            'success' => true,
            'data' => $data,
            'meta' => [
                'requestId' => request()->headers->get('X-Request-Id') ?: (string) Str::uuid(),
                'endpoint' => request()->path(),
                'elapsedMs' => round((microtime(true) - $started) * 1000, 2),
                'generatedAt' => now()->toIso8601String(),
                'servedFrom' => $this->responseServedFrom($data),
                'snapshotAgeSeconds' => $snapshotAgeSeconds,
                'lastSyncedAt' => $lastSyncedAt,
                'refreshInProgress' => is_array($data) && (bool) ($data['refreshing'] ?? false),
                'geotab_available' => $this->responseGeotabAvailable($data),
                'geotabAvailable' => $this->responseGeotabAvailable($data),
            ],
        ];

        $geotabReason = $this->responseGeotabReason($data);
        if ($geotabReason !== null) {
            $payload['meta']['reason'] = $geotabReason;
            $payload['meta']['geotabReason'] = $geotabReason;
        }

        if ($pagination !== null) {
            $payload['meta']['pagination'] = $pagination;
        }

        if (config('app.debug')) {
            $payload['meta']['debug'] = true;
        }

        return response()
            ->json($payload)
            ->withHeaders([
                'X-Pioneer-Elapsed-Ms' => (string) $payload['meta']['elapsedMs'],
                'X-Pioneer-Served-From' => (string) $payload['meta']['servedFrom'],
            ]);
    }

    private function shouldPaginateResponse(mixed $data): bool
    {
        return request()->isMethod('GET')
            && is_array($data)
            && array_is_list($data)
            && request()->is('api/fleet/*', 'api/billing/*', 'api/vehicles/*');
    }

    /**
     * @param  array<string, mixed>  $payload
     * @return array<string, mixed>
     */
    private function withPaginatedList(array $payload, string $key): array
    {
        if (! request()->isMethod('GET') || ! is_array($payload[$key] ?? null)) {
            return $payload;
        }

        $pagination = $this->paginationPayload($payload[$key]);
        $payload[$key] = $pagination['data'];
        unset($pagination['data']);
        $payload['_pagination'] = $pagination;

        return $payload;
    }

    /**
     * @param  array<int, mixed>  $items
     * @return array<string, mixed>
     */
    private function paginationPayload(array $items): array
    {
        $request = request();
        $total = count($items);
        $perPage = max(1, min(100, (int) $request->query('perPage', $request->query('per_page', 25))));
        $page = max(1, (int) $request->query('page', 1));
        $lastPage = max(1, (int) ceil($total / $perPage));
        $page = min($page, $lastPage);
        $offset = ($page - 1) * $perPage;

        return [
            'data' => array_values(array_slice($items, $offset, $perPage)),
            'total' => $total,
            'currentPage' => $page,
            'current_page' => $page,
            'perPage' => $perPage,
            'per_page' => $perPage,
            'lastPage' => $lastPage,
            'last_page' => $lastPage,
            'nextPage' => $page < $lastPage ? $page + 1 : null,
            'previousPage' => $page > 1 ? $page - 1 : null,
            'nextPageUrl' => $page < $lastPage ? $this->paginationUrl($page + 1, $perPage) : null,
            'previousPageUrl' => $page > 1 ? $this->paginationUrl($page - 1, $perPage) : null,
        ];
    }

    private function paginationUrl(int $page, int $perPage): string
    {
        $request = request();
        $query = [
            ...$request->query(),
            'page' => $page,
            'perPage' => $perPage,
        ];

        return $request->url().'?'.http_build_query($query);
    }

    private function emitSseEvent(array $event): void
    {
        $id = (string) ($event['id'] ?? Str::uuid());
        $name = (string) ($event['event'] ?? 'message');
        $data = $event['data'] ?? [];

        echo 'id: '.$id."\n";
        echo 'event: '.$name."\n";
        echo 'data: '.json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)."\n\n";

        if (ob_get_level() > 0) {
            @ob_flush();
        }
        @flush();
    }

    private function responseServedFrom(mixed $data): string
    {
        if (! is_array($data)) {
            return 'api';
        }

        if ((bool) ($data['refreshing'] ?? false)) {
            return 'stale_snapshot';
        }

        if ((bool) ($data['stale'] ?? false)) {
            return 'stale_snapshot';
        }

        if (($data['lastSyncedAt'] ?? null) !== null || ($data['lastUpdated'] ?? null) !== null) {
            return 'snapshot';
        }

        return 'api';
    }

    private function responseGeotabAvailable(mixed $data): bool
    {
        if (is_array($data) && array_key_exists('geotabAvailable', $data)) {
            return (bool) $data['geotabAvailable'];
        }

        if (is_array($data) && array_key_exists('geotab_available', $data)) {
            return (bool) $data['geotab_available'];
        }

        return $this->geotabAvailable;
    }

    private function responseGeotabReason(mixed $data): ?string
    {
        if (is_array($data)) {
            $reason = $data['geotabReason'] ?? $data['geotab_reason'] ?? null;
            if (is_string($reason) && trim($reason) !== '') {
                return trim($reason);
            }
        }

        return $this->geotabUnavailableReason;
    }

    private function markGeotabUnavailable(string $reason): void
    {
        $this->geotabAvailable = false;
        $this->geotabUnavailableReason = $reason;
    }

    private function respondError(string $message, int $status): JsonResponse
    {
        return response()->json([
            'success' => false,
            'message' => $message,
        ], $status);
    }

    private function startEndpointTiming(string $endpoint, array $context = []): array
    {
        $requestId = (string) Str::uuid();
        $startedAt = now()->toIso8601String();
        $requestStartedAt = microtime(true);

        $payload = array_filter([
            'requestId' => $requestId,
            'endpoint' => $endpoint,
            'geotabId' => $context['geotabId'] ?? null,
            'startedAt' => $startedAt,
        ], fn ($value) => $value !== null);

        Log::withContext($payload);
        $this->geotab->setTimingContext($requestId, $endpoint, $requestStartedAt);
        $this->timingLog('endpoint.start', $payload);

        return [
            'requestId' => $requestId,
            'endpoint' => $endpoint,
            'startedHrtime' => hrtime(true),
        ];
    }

    private function finishEndpointTiming(array $timing, string $result, array $context = []): void
    {
        $this->timingLog('endpoint.finish', [
            'requestId' => $timing['requestId'] ?? null,
            'endpoint' => $timing['endpoint'] ?? null,
            'result' => $result,
            'elapsedMs' => $this->elapsedMs((int) ($timing['startedHrtime'] ?? hrtime(true))),
            ...$context,
        ]);
    }

    private function timingLog(string $event, array $context = []): void
    {
        Log::channel('geotab')->info('GEOTAB_TIMING '.$event, array_filter(
            $context,
            fn ($value) => $value !== null
        ));
    }

    private function elapsedMs(int $started): float
    {
        return round((hrtime(true) - $started) / 1000000, 2);
    }

    private function snapshotState(array $snapshot): string
    {
        if (($snapshot['stale'] ?? false) === true) {
            return 'stale';
        }

        return $this->isEmptySnapshotPayload($snapshot) ? 'empty' : 'fresh';
    }

    private function isEmptySnapshotPayload(array $snapshot): bool
    {
        return empty($snapshot['vehicles'] ?? [])
            && empty($snapshot['drivers'] ?? [])
            && empty($snapshot['trips'] ?? [])
            && empty($snapshot['routes'] ?? [])
            && empty($snapshot['zones'] ?? [])
            && empty(data_get($snapshot, 'telemetry.assets', []));
    }

    private function historyHasRows(array $history): bool
    {
        foreach ($history as $rows) {
            if (is_array($rows) && $rows !== []) {
                return true;
            }
        }

        return false;
    }

    private function classifyThrowable(?\Throwable $e): ?string
    {
        if (! $e instanceof \Throwable) {
            return null;
        }

        $message = strtolower($e->getMessage());
        if (
            str_contains($message, 'timed out')
            || str_contains($message, 'timeout')
            || str_contains($message, 'curl error 28')
            || str_contains($message, 'maximum execution time')
        ) {
            return 'timeout';
        }

        if (
            str_contains($message, 'connection refused')
            || str_contains($message, 'could not resolve host')
            || str_contains($message, 'failed to connect')
            || str_contains($message, 'curl error')
        ) {
            return 'connection_error';
        }

        if (
            str_contains($message, 'geotab')
            || str_contains($message, 'authenticate with geotab')
            || str_contains($message, 'auth failed')
        ) {
            return 'geotab_api_error';
        }

        return 'php_exception';
    }

    private function idFromValue(mixed $value): string
    {
        if (is_array($value)) {
            return (string) ($value['id'] ?? '');
        }

        if (is_string($value)) {
            return $value;
        }

        return '';
    }

    private function userDisplayName(mixed $user): string
    {
        if (! is_array($user)) {
            return '';
        }

        $first = $this->sanitizeText($user['firstName'] ?? '', '');
        $last = $this->sanitizeText($user['lastName'] ?? '', '');
        $full = trim($first.' '.$last);
        if ($full !== '') {
            return $full;
        }

        $name = $this->sanitizeText($user['name'] ?? '', '');
        if ($name !== '') {
            return $name;
        }

        return $this->sanitizeText($user['id'] ?? '', '');
    }

    private function plateForDevice(array $device): string
    {
        $plate = $this->sanitizeText(data_get($device, 'licensePlate', ''), '');
        if ($plate !== '') {
            return strtoupper($plate);
        }

        return strtoupper($this->sanitizeText(data_get($device, 'name', ''), 'UNKNOWN'));
    }

    private function stringValue(mixed $value): string
    {
        if (is_array($value)) {
            return $this->sanitizeText($value['name'] ?? $value['id'] ?? '', '');
        }

        return $this->sanitizeText($value, '');
    }

    private function sanitizeText(mixed $value, string $fallback): string
    {
        if (is_array($value)) {
            foreach (['name', 'displayName', 'id', 'value', 'code'] as $key) {
                if (array_key_exists($key, $value) && ! is_array($value[$key])) {
                    $value = $value[$key];
                    break;
                }
            }

            if (is_array($value)) {
                return $fallback;
            }
        }

        $text = trim((string) $value);
        if ($text === '') {
            return $fallback;
        }

        $decoded = html_entity_decode($text, ENT_QUOTES | ENT_HTML5, 'UTF-8');
        if (function_exists('mb_check_encoding') && ! mb_check_encoding($decoded, 'UTF-8')) {
            $decoded = mb_convert_encoding($decoded, 'UTF-8', 'UTF-8');
        }

        $decoded = trim($decoded);
        $decoded = str_replace("\u{00A0}", ' ', $decoded);
        $decoded = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u', '', $decoded) ?? '';
        $decoded = preg_replace('/[ \t]+/u', ' ', $decoded) ?? '';
        $decoded = trim($decoded);

        return $decoded === '' ? $fallback : $decoded;
    }

    private function nullableCleanText(mixed $value): ?string
    {
        $text = $this->sanitizeText($value, '');

        return $text === '' ? null : $text;
    }

    private function vehicleYear(array $device): string
    {
        $comment = $this->sanitizeText(data_get($device, 'comment', ''), '');
        if (preg_match('/\b(19\d{2}|20\d{2})\b/', $comment, $match) === 1) {
            return $match[1];
        }

        return 'N/A';
    }

    private function assetProfileForDevice(array $device): array
    {
        $make = $this->sanitizeText(data_get($device, 'vinInfoMake', ''), '');
        $model = $this->sanitizeText(data_get($device, 'vinInfoModel', ''), '');
        $comment = $this->sanitizeText(data_get($device, 'comment', ''), '');
        $name = $this->sanitizeText(data_get($device, 'name', ''), '');
        $haystack = strtolower($name.' '.$comment.' '.$make.' '.$model);

        if ($make === '' || $model === '') {
            foreach (['Toyota Hilux', 'Nissan NP300 Navara', 'Toyota Lite Ace', 'Isuzu N-Series', 'Mitsubishi Fuso Canter', 'Hino 500'] as $candidate) {
                if (str_contains($haystack, strtolower($candidate))) {
                    [$make, $model] = explode(' ', $candidate, 2);
                    break;
                }
            }
        }

        $makeModel = trim($make.' '.$model);
        if ($makeModel === '') {
            $makeModel = $comment !== '' ? $comment : $name;
        }

        $year = $this->vehicleYear($device);
        if ($year === 'N/A' && preg_match('/\b(19\d{2}|20\d{2})\b/', $makeModel.' '.$name, $match) === 1) {
            $year = $match[1];
        }

        $vehicleType = match (true) {
            str_contains($haystack, 'car carrier') => 'Car Carrier',
            str_contains($haystack, 'lite ace') || str_contains($haystack, 'van') => 'Van',
            str_contains($haystack, 'hilux') || str_contains($haystack, 'navara') || str_contains($haystack, 'pickup') => 'Pickup',
            str_contains($haystack, 'wing') => 'Wing Van',
            str_contains($haystack, 'tractor') || str_contains($haystack, 'trailer') => 'Heavy Truck',
            default => $this->inferTruckType($device),
        };

        $cargoCapacityKg = match ($vehicleType) {
            'Pickup' => str_contains($haystack, 'navara') ? 1100 : 1000,
            'Van' => str_contains($haystack, 'lite ace') ? 750 : 1800,
            'Wing Van' => 6500,
            'Car Carrier' => 5000,
            'Heavy Truck' => 9000,
            default => 3000 + (($this->stableVehicleSeed($device) % 5) * 500),
        };

        return [
            'makeModel' => $makeModel !== '' ? $makeModel : 'Fleet asset '.$this->plateForDevice($device),
            'year' => $year !== 'N/A' ? $year : (string) (2019 + ($this->stableVehicleSeed($device) % 7)),
            'vehicleType' => $vehicleType !== '' ? $vehicleType : 'Vehicle',
            'cargoCapacityKg' => $cargoCapacityKg,
            ...$this->estimatedComplianceDates($device),
        ];
    }

    private function estimatedComplianceDates(array $device): array
    {
        $seed = $this->stableVehicleSeed($device);
        $registration = now()->startOfDay()->addDays(45 + ($seed % 250));
        $insurance = now()->startOfDay()->addDays(30 + (($seed >> 3) % 220));

        return [
            'registrationExpiryDate' => $registration->toDateString(),
            'insuranceExpiryDate' => $insurance->toDateString(),
            'registrationDaysRemaining' => now()->startOfDay()->diffInDays($registration, false),
            'insuranceDaysRemaining' => now()->startOfDay()->diffInDays($insurance, false),
        ];
    }

    private function inferTruckType(array $device): string
    {
        $haystack = strtolower(
            $this->sanitizeText(data_get($device, 'comment', ''), '').' '.
            $this->sanitizeText(data_get($device, 'name', ''), '')
        );
        foreach (['4 wheeler', '6 wheeler', '10 wheeler', '12 wheeler', 'wing van', 'tractor head', 'trailer'] as $type) {
            if (str_contains($haystack, $type)) {
                return ucwords($type);
            }
        }

        $deviceType = $this->stringValue(data_get($device, 'deviceType'));

        return $deviceType !== '' ? $deviceType : 'Truck';
    }

    private function parseDate(mixed $value): ?Carbon
    {
        if (! is_string($value) || trim($value) === '') {
            return null;
        }

        try {
            return Carbon::parse($value);
        } catch (\Throwable) {
            return null;
        }
    }

    private function displayDate(?Carbon $date): string
    {
        return $date?->format('M j, h:i A') ?? 'N/A';
    }

    private function displayShortDate(?Carbon $date): string
    {
        return $date?->format('M j, Y') ?? 'N/A';
    }

    private function buildAddressLookup(array $trips, array $statusList): array
    {
        $coordinates = [];

        foreach ($trips as $trip) {
            foreach (['startPoint', 'stopPoint'] as $field) {
                $parts = $this->coordinateParts(data_get($trip, $field));
                if ($parts === null) {
                    continue;
                }

                $coordinates[$this->coordinateLookupKey($parts)] = [
                    'x' => $parts['longitude'],
                    'y' => $parts['latitude'],
                ];
            }
        }

        foreach ($statusList as $status) {
            $parts = $this->coordinateParts($status);
            if ($parts === null) {
                continue;
            }

            $coordinates[$this->coordinateLookupKey($parts)] = [
                'x' => $parts['longitude'],
                'y' => $parts['latitude'],
            ];
        }

        if ($coordinates === []) {
            return [];
        }

        $lookup = [];
        $missing = [];

        foreach ($coordinates as $key => $coordinate) {
            $cached = Cache::get($this->addressCacheKey($key));
            if (is_array($cached) && $cached !== []) {
                $lookup[$key] = $cached;

                continue;
            }

            $missing[$key] = $coordinate;
        }

        foreach ($missing as $key => $coordinate) {
            $googleAddress = $this->googleMaps->reverseGeocode([
                'latitude' => $coordinate['y'],
                'longitude' => $coordinate['x'],
            ]);

            if (is_array($googleAddress) && $googleAddress !== []) {
                $formatted = $this->formatReverseGeocodeAddress($googleAddress);
                $formatted['source'] = 'google_geocoding';
                $lookup[$key] = $formatted;
                Cache::put($this->addressCacheKey($key), $formatted, now()->addHours(24));
                unset($missing[$key]);
            }
        }

        foreach (array_chunk($missing, 40, true) as $chunk) {
            $addresses = $this->safeGet(fn () => $this->geotab->getAddresses(array_values($chunk), true));
            $keys = array_keys($chunk);

            foreach ($addresses as $index => $address) {
                $key = $keys[$index] ?? null;
                if ($key === null) {
                    continue;
                }

                $formatted = $this->formatReverseGeocodeAddress((array) $address);
                $formatted['source'] = 'geotab_get_addresses';
                $lookup[$key] = $formatted;
                Cache::put($this->addressCacheKey($key), $formatted, now()->addHours(24));
            }
        }

        return $lookup;
    }

    private function addressCacheKey(string $lookupKey): string
    {
        return 'geotab_reverse_geocode_'.md5($lookupKey);
    }

    private function addressLabelForLookup(mixed $coordinate, array $lookup, string $fallback): string
    {
        $parts = $this->coordinateParts($coordinate);
        if ($parts === null) {
            return $fallback;
        }

        $address = $lookup[$this->coordinateLookupKey($parts)] ?? null;
        $formatted = trim((string) data_get($address, 'formattedAddress', ''));

        if ($formatted !== '') {
            return $this->sanitizeText($formatted, $fallback);
        }

        return $this->coordinateLabelCardinal($parts, $fallback);
    }

    private function formatReverseGeocodeAddress(array $address): array
    {
        $zones = [];
        foreach ((array) data_get($address, 'zones', []) as $zone) {
            $zoneName = $this->sanitizeText(data_get($zone, 'name', ''), '');
            if ($zoneName !== '') {
                $zones[] = $zoneName;
            }
        }

        return [
            'formattedAddress' => $this->sanitizeText(data_get($address, 'formattedAddress', ''), ''),
            'street' => $this->sanitizeText(data_get($address, 'street', ''), ''),
            'city' => $this->sanitizeText(data_get($address, 'city', ''), ''),
            'country' => $this->sanitizeText(data_get($address, 'country', ''), ''),
            'zones' => $zones,
        ];
    }

    private function gpsTrailForTrip(array $trip, string $deviceId, ?Carbon $start, ?Carbon $end): array
    {
        return $this->gpsTrailForTripWithSource($trip, $deviceId, $start, $end)['points'];
    }

    private function gpsTrailForTripWithSource(array $trip, string $deviceId, ?Carbon $start, ?Carbon $end): array
    {
        if (! Schema::hasTable('gps_logs')) {
            return ['points' => [], 'source' => 'none'];
        }

        $tripId = trim((string) ($trip['tripId'] ?? ''));
        if ($tripId !== '') {
            $logs = $this->gpsLogQueryForWindow(
                GpsLog::query()->where('trip_id', $tripId),
                $start,
                $end,
            )->orderBy('recorded_at')->limit(1000)->get();
            if ($logs->count() >= 2 || $deviceId === '') {
                $points = $this->formatGpsLogModels($logs);

                return [
                    'points' => $points,
                    'source' => $points === [] ? 'none' : 'gps_logs_trip_id',
                ];
            }
        }

        if ($deviceId === '') {
            return ['points' => [], 'source' => 'none'];
        }

        $logs = $this->gpsLogQueryForWindow(
            GpsLog::query()->where('device_geotab_id', $deviceId),
            $start,
            $end,
        )->orderBy('recorded_at')->limit(1000)->get();

        $points = $this->formatGpsLogModels($logs);

        return [
            'points' => $points,
            'source' => $points === [] ? 'none' : 'gps_logs_device_time_window',
        ];
    }

    private function gpsLogCountForTrip(string $tripId): int
    {
        if ($tripId === '' || ! Schema::hasTable('gps_logs')) {
            return 0;
        }

        return GpsLog::query()->where('trip_id', $tripId)->count();
    }

    private function gpsLogQueryForWindow(mixed $query, ?Carbon $start, ?Carbon $end): mixed
    {
        if ($start !== null) {
            $query->where('recorded_at', '>=', $start->copy()->subMinutes(3));
        }
        if ($end !== null) {
            $query->where('recorded_at', '<=', $end->copy()->addMinutes(3));
        }

        return $query;
    }

    private function formatGpsLogModels(mixed $logs): array
    {
        return $logs->map(fn (GpsLog $log): array => [
            'latitude' => (float) $log->latitude,
            'longitude' => (float) $log->longitude,
            'speed' => (float) $log->speed,
            'bearing' => $log->bearing,
            'dateTime' => $log->recorded_at?->toIso8601String(),
        ])->all();
    }

    private function persistGpsTrailForTrip(array $logs, array $trip, string $deviceId): void
    {
        $tripId = trim((string) ($trip['tripId'] ?? '')) ?: null;
        foreach ($logs as $log) {
            if (is_array($log)) {
                $this->persistGpsLogRow($log, $tripId, $deviceId);
            }
        }
    }

    private function persistGpsLogRow(
        array $row,
        ?string $tripId,
        ?string $deviceId = null,
        ?float $bearing = null,
    ): void {
        if (! Schema::hasTable('gps_logs')) {
            return;
        }

        $resolvedDeviceId = trim((string) ($deviceId ?: $this->idFromValue(data_get($row, 'device'))));
        $point = $this->coordinateParts($row);
        $recordedAt = $this->parseDate(data_get($row, 'dateTime'));
        if ($resolvedDeviceId === '' || $point === null || $recordedAt === null) {
            return;
        }

        $geotabLogId = $this->idFromValue($row);
        if ($geotabLogId === '') {
            $geotabLogId = sha1($resolvedDeviceId.'|'.$recordedAt->toIso8601String().'|'.$point['latitude'].'|'.$point['longitude']);
        }

        GpsLog::query()->updateOrCreate(
            ['geotab_log_id' => $geotabLogId],
            [
                'trip_id' => $tripId,
                'device_geotab_id' => $resolvedDeviceId,
                'latitude' => $point['latitude'],
                'longitude' => $point['longitude'],
                'speed' => (float) data_get($row, 'speed', 0),
                'bearing' => $bearing,
                'recorded_at' => $recordedAt,
                'meta' => [
                    'source' => 'geotab_log_record',
                    'rawId' => $this->idFromValue($row),
                ],
            ],
        );
    }

    private function formatTrailPoints(array $logs): array
    {
        return array_values(array_filter(array_map(function (array $log): ?array {
            $point = $this->coordinateParts($log);
            if ($point === null) {
                return null;
            }

            return [
                'latitude' => (float) ($point['latitude'] ?? 0),
                'longitude' => (float) ($point['longitude'] ?? 0),
                'speed' => (int) data_get($log, 'speed', 0),
                'dateTime' => data_get($log, 'dateTime'),
            ];
        }, $logs)));
    }

    private function coordinateLookupKey(array $parts): string
    {
        return number_format((float) $parts['latitude'], 5, '.', '')
            .':'
            .number_format((float) $parts['longitude'], 5, '.', '');
    }

    private function coordinateLabel(mixed $coordinate, string $fallback): string
    {
        if (! is_array($coordinate)) {
            return $fallback;
        }

        $latitude = (float) ($coordinate['latitude'] ?? 0);
        $longitude = (float) ($coordinate['longitude'] ?? 0);

        if ($latitude === 0.0 && $longitude === 0.0) {
            return $fallback;
        }

        return $this->coordinateLabelCardinal([
            'latitude' => $latitude,
            'longitude' => $longitude,
        ], $fallback);
    }

    private function coordinateLabelCardinal(array $parts, string $fallback): string
    {
        $latitude = (float) ($parts['latitude'] ?? 0);
        $longitude = (float) ($parts['longitude'] ?? 0);

        if ($latitude === 0.0 && $longitude === 0.0) {
            return $fallback;
        }

        return number_format(abs($latitude), 4).'°'.($latitude >= 0 ? 'N' : 'S')
            .', '
            .number_format(abs($longitude), 4).'°'.($longitude >= 0 ? 'E' : 'W');
    }

    private function predictiveSnapshot(): array
    {
        $fresh = Cache::get(self::SNAPSHOT_FRESH_KEY);
        if (is_array($fresh) && $fresh !== []) {
            return $fresh;
        }

        $stale = Cache::get(self::SNAPSHOT_STALE_KEY);
        if (is_array($stale) && $stale !== []) {
            return $stale;
        }

        return $this->emptySnapshot();
    }

    private function maintenancePredictionsPayload(): array
    {
        $snapshot = $this->predictiveSnapshot();
        $vehicles = is_array($snapshot['vehicles'] ?? null) ? $snapshot['vehicles'] : [];
        $history = $this->maintenanceHistoryTableAvailable()
            ? MaintenanceHistory::query()->orderBy('recorded_at')->get()
            : collect();
        $knownVehicleKeys = [];
        foreach ($vehicles as $vehicle) {
            $plate = $this->sanitizeText($vehicle['plate'] ?? $vehicle['vehicle'] ?? '', '');
            $geotabId = $this->sanitizeText($vehicle['geotabId'] ?? '', '');
            if ($plate !== '') {
                $knownVehicleKeys['plate:'.strtoupper($plate)] = true;
            }
            if ($geotabId !== '') {
                $knownVehicleKeys['device:'.$geotabId] = true;
            }
        }

        foreach ($history as $row) {
            $plate = $this->sanitizeText($row->vehicle_plate, '');
            $geotabId = $this->sanitizeText($row->vehicle_geotab_id, '');
            $plateKey = $plate !== '' ? 'plate:'.strtoupper($plate) : null;
            $deviceKey = $geotabId !== '' ? 'device:'.$geotabId : null;
            if (($plateKey !== null && isset($knownVehicleKeys[$plateKey]))
                || ($deviceKey !== null && isset($knownVehicleKeys[$deviceKey]))) {
                continue;
            }
            if ($plate === '' && $geotabId === '') {
                continue;
            }

            $vehicles[] = [
                'plate' => $plate !== '' ? $plate : 'Unknown',
                'vehicle' => $plate !== '' ? $plate : $geotabId,
                'geotabId' => $geotabId,
                'odometerKm' => $this->maintenanceRecordOdometerKm($row),
            ];
            if ($plateKey !== null) {
                $knownVehicleKeys[$plateKey] = true;
            }
            if ($deviceKey !== null) {
                $knownVehicleKeys[$deviceKey] = true;
            }
        }

        $rows = [];
        foreach ($vehicles as $vehicle) {
            $plate = $this->sanitizeText($vehicle['plate'] ?? $vehicle['vehicle'] ?? '', 'Unknown');
            $geotabId = $this->sanitizeText($vehicle['geotabId'] ?? '', '');
            $records = $history->filter(function (MaintenanceHistory $row) use ($plate, $geotabId): bool {
                return ($plate !== 'Unknown' && (string) $row->vehicle_plate === $plate)
                    || ($geotabId !== '' && (string) $row->vehicle_geotab_id === $geotabId);
            })->values();
            if ($records->isEmpty()) {
                continue;
            }

            $last = $records->last();
            $avgDays = 90;
            $avgKm = 5000.0;
            if ($records->count() >= 2) {
                $dayGaps = [];
                $kmGaps = [];
                for ($index = 1; $index < $records->count(); $index++) {
                    $previous = $records[$index - 1];
                    $current = $records[$index];
                    if ($previous->recorded_at !== null && $current->recorded_at !== null) {
                        $dayGaps[] = max(1, abs(Carbon::parse($previous->recorded_at)->diffInDays(Carbon::parse($current->recorded_at))));
                    }

                    $previousKm = $this->maintenanceRecordOdometerKm($previous);
                    $currentKm = $this->maintenanceRecordOdometerKm($current);
                    if ($previousKm !== null && $currentKm !== null) {
                        $kmGaps[] = max(1, abs($currentKm - $previousKm));
                    }
                }

                if ($dayGaps !== []) {
                    $avgDays = max(14, (int) round(array_sum($dayGaps) / count($dayGaps)));
                }

                if ($kmGaps !== []) {
                    $avgKm = max(1000.0, round(array_sum($kmGaps) / count($kmGaps), 1));
                }
            }

            $lastDate = $last?->recorded_at ? Carbon::parse($last->recorded_at) : now()->subDays(45);
            $lastKm = $last ? $this->maintenanceRecordOdometerKm($last) : null;
            $currentKm = $this->vehicleOdometerKm($vehicle) ?? $lastKm ?? 0.0;
            $nextDue = $last?->next_due_at ? Carbon::parse($last->next_due_at) : $lastDate->copy()->addDays($avgDays);
            $nextDueKm = $lastKm !== null ? round($lastKm + $avgKm, 1) : round($currentKm + $avgKm, 1);
            $daysRemaining = (int) now()->startOfDay()->diffInDays($nextDue->copy()->startOfDay(), false);
            $warningDays = max(0, (int) $this->systemSettingsValue('maintenance_due_warning_days', 14));
            $state = $daysRemaining < 0 ? 'overdue' : ($daysRemaining <= $warningDays ? 'due_soon' : 'normal');

            $rows[] = [
                'vehicle' => $plate,
                'plate' => $plate,
                'geotabId' => $geotabId,
                'averageIntervalDays' => $avgDays,
                'averageIntervalKm' => round($avgKm, 1),
                'lastServiceAt' => $lastDate->toDateString(),
                'lastServiceKm' => $lastKm,
                'currentKm' => round($currentKm, 1),
                'nextDueDate' => $nextDue->toDateString(),
                'nextDueKm' => $nextDueKm,
                'daysRemaining' => $daysRemaining,
                'state' => $state,
                'label' => $daysRemaining < 0 ? abs($daysRemaining).' days overdue' : $daysRemaining.' days remaining',
            ];
        }

        usort($rows, fn (array $a, array $b): int => ((int) $a['daysRemaining']) <=> ((int) $b['daysRemaining']));

        return [
            'generatedAt' => now()->toIso8601String(),
            'cacheTtlSeconds' => 3600,
            'vehicles' => $rows,
            'topUrgent' => array_slice($rows, 0, 3),
        ];
    }

    private function driverPerformancePayload(): array
    {
        $snapshot = $this->predictiveSnapshot();
        $trips = is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [];
        $drivers = is_array($snapshot['drivers'] ?? null) ? $snapshot['drivers'] : [];
        $monthStart = now()->startOfMonth();
        $stats = [];
        $driverResolver = $this->driverNameResolver($drivers);

        foreach ($drivers as $driver) {
            $name = $this->resolveAnalyticsDriverName($driver['name'] ?? $driver['driver'] ?? $driver['driverId'] ?? null, $driverResolver);
            $stats[$name] = $this->emptyDriverPerformanceRow($name);
        }

        foreach ($trips as $trip) {
            $date = $this->parseDate($trip['startedAt'] ?? $trip['endedAt'] ?? $trip['date'] ?? null);
            if ($date !== null && $date->lessThan($monthStart)) {
                continue;
            }

            $driver = $this->resolveAnalyticsDriverName($trip['driver'] ?? $trip['driverName'] ?? $trip['driverId'] ?? null, $driverResolver);
            $stats[$driver] ??= $this->emptyDriverPerformanceRow($driver);
            $stats[$driver]['totalTrips']++;
            $stats[$driver]['totalKm'] += (float) ($trip['distanceKm'] ?? $trip['actualDistanceKm'] ?? 0);
            $arrivalState = strtolower((string) ($trip['arrivalState'] ?? $trip['slaState'] ?? $trip['timeliness'] ?? ''));
            if ($arrivalState !== '') {
                $stats[$driver]['timedTrips']++;
                if (! str_contains($arrivalState, 'late') && ! str_contains($arrivalState, 'delay')) {
                    $stats[$driver]['onTimeTrips']++;
                }
            }
        }

        foreach ($stats as $name => $row) {
            $rate = (int) $row['timedTrips'] > 0 ? (float) $row['onTimeTrips'] / (float) $row['timedTrips'] : 0.0;
            $stats[$name]['totalKm'] = round((float) $row['totalKm'], 1);
            $stats[$name]['onTimeRate'] = round($rate, 4);
            $stats[$name]['onTimeLabel'] = (int) $row['timedTrips'] > 0 ? round($rate * 100).'%' : 'N/A';
            $stats[$name]['score'] = round(($rate * 70) + min(30, (int) $row['totalTrips'] * 3), 1);
        }

        $ranked = array_values($stats);
        usort($ranked, fn (array $a, array $b): int => ((float) $b['score'] <=> (float) $a['score']) ?: ((int) $b['totalTrips'] <=> (int) $a['totalTrips']));
        foreach ($ranked as $index => $row) {
            $ranked[$index]['rank'] = $index + 1;
        }

        return [
            'generatedAt' => now()->toIso8601String(),
            'cacheTtlSeconds' => 600,
            'month' => now()->format('Y-m'),
            'rankedDrivers' => $ranked,
            'topDrivers' => array_slice($ranked, 0, 5),
            'bottomDrivers' => array_slice(array_values(array_reverse($ranked)), 0, 5),
        ];
    }

    private function driverNameResolver(array $drivers): array
    {
        $resolver = [];
        $remember = function (mixed $key, mixed $name) use (&$resolver): void {
            $key = strtolower(trim((string) $key));
            $name = trim((string) $name);
            if ($key === '' || ! $this->looksLikeHumanDriverName($name)) {
                return;
            }

            $resolver[$key] = $name;
        };

        foreach ($drivers as $driver) {
            if (! is_array($driver)) {
                continue;
            }

            $name = $this->sanitizeText($driver['name'] ?? $driver['driver'] ?? '', '');
            foreach (['name', 'driver', 'driverId', 'id', 'geotabId', 'geotabUserId', 'email', 'employeeNumber', 'assignedVehicleGeotabId'] as $field) {
                $remember($driver[$field] ?? null, $name);
            }
        }

        foreach ($this->loadManualDrivers() as $driver) {
            $name = $this->sanitizeText($driver['name'] ?? '', '');
            foreach (['name', 'driverId', 'id', 'geotabId', 'geotabUserId', 'email', 'employeeNumber', 'assignedVehicleGeotabId', 'assignedVehicle'] as $field) {
                $remember($driver[$field] ?? null, $name);
            }
        }

        if (Schema::hasTable('users')) {
            User::query()
                ->whereIn('role', ['driver'])
                ->get(['id', 'name', 'email'])
                ->each(function (User $user) use ($remember): void {
                    $remember($user->id, $user->name);
                    $remember($user->email, $user->name);
                    $remember($user->name, $user->name);
                });
        }

        return $resolver;
    }

    private function resolveAnalyticsDriverName(mixed $value, array $resolver): string
    {
        $raw = is_array($value)
            ? ($this->userDisplayName($value) ?: $this->idFromValue($value))
            : $this->sanitizeText($value, '');
        $key = strtolower(trim($raw));

        if ($key !== '' && isset($resolver[$key])) {
            return $resolver[$key];
        }

        if ($this->looksLikeHumanDriverName($raw)) {
            return trim($raw);
        }

        return 'Unassigned Driver';
    }

    private function looksLikeHumanDriverName(string $value): bool
    {
        $value = trim($value);
        $lower = strtolower($value);
        if ($value === '' || in_array($lower, ['n/a', 'unknown', 'unknown driver', 'unavailable'], true)) {
            return false;
        }

        if (preg_match('/^[a-z][0-9a-z]{1,5}$/i', $value) === 1) {
            return false;
        }

        if (preg_match('/^[0-9a-f]{6,}$/i', $value) === 1) {
            return false;
        }

        return str_contains($value, ' ') || strlen($value) > 6;
    }

    private function vehicleHealthPayload(): array
    {
        $snapshot = $this->predictiveSnapshot();
        $vehicles = is_array($snapshot['vehicles'] ?? null) ? $snapshot['vehicles'] : [];
        $faults = is_array($snapshot['maintenanceFaults'] ?? null) ? $snapshot['maintenanceFaults'] : [];
        $predictions = collect($this->maintenancePredictionsPayload()['vehicles'] ?? [])->keyBy('plate');

        $faultsByVehicle = [];
        foreach ($faults as $fault) {
            $plate = $this->sanitizeText($fault['vehicle'] ?? $fault['plate'] ?? '', 'Unknown');
            $faultsByVehicle[$plate] = ($faultsByVehicle[$plate] ?? 0) + 1;
        }

        $rows = [];
        foreach ($vehicles as $vehicle) {
            $plate = $this->sanitizeText($vehicle['plate'] ?? $vehicle['vehicle'] ?? '', 'Unknown');
            $prediction = $predictions->get($plate, []);
            $lastServiceAt = $this->parseDate($prediction['lastServiceAt'] ?? null) ?? now()->subDays(90);
            $daysSince = max(0, (int) $lastServiceAt->diffInDays(now()));
            $faultCount = (int) ($faultsByVehicle[$plate] ?? 0);
            $currentKm = $this->vehicleOdometerKm($vehicle) ?? (float) ($prediction['currentKm'] ?? 0);
            $lastKm = isset($prediction['lastServiceKm']) ? (float) $prediction['lastServiceKm'] : max(0, $currentKm - 5000);
            $kmSince = max(0, $currentKm - $lastKm);
            $score = min(100, (int) round(min(45, ($daysSince / 120) * 45) + min(35, $faultCount * 10) + min(20, $kmSince / 250)));

            $rows[] = [
                'vehicle' => $plate,
                'plate' => $plate,
                'riskScore' => $score,
                'riskLevel' => $score > 80 ? 'red' : ($score > 60 ? 'amber' : 'green'),
                'daysSinceMaintenance' => $daysSince,
                'daysSinceLastMaintenance' => $daysSince,
                'faultCodeCount' => $faultCount,
                'kmSinceService' => round($kmSince, 1),
                'kmSinceLastService' => round($kmSince, 1),
            ];
        }

        usort($rows, fn (array $a, array $b): int => ((int) $b['riskScore']) <=> ((int) $a['riskScore']));

        return [
            'generatedAt' => now()->toIso8601String(),
            'cacheTtlSeconds' => 600,
            'vehicles' => $rows,
            'amberThreshold' => 60,
            'redThreshold' => 80,
        ];
    }

    private function routeEfficiencyPayload(): array
    {
        $snapshot = $this->predictiveSnapshot();
        $trips = is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [];
        $routes = [];

        foreach ($trips as $trip) {
            $routeName = $this->sanitizeText($trip['routeName'] ?? $trip['routeText'] ?? '', '');
            if ($routeName === '') {
                $origin = $this->sanitizeText($trip['origin'] ?? '', 'Origin');
                $destination = $this->sanitizeText($trip['destination'] ?? '', 'Destination');
                $routeName = $origin.' -> '.$destination;
            }

            $routes[$routeName] ??= [
                'route' => $routeName,
                'tripCount' => 0,
                'plannedDistanceKm' => 0.0,
                'actualDistanceKm' => 0.0,
            ];
            $routes[$routeName]['tripCount']++;
            $planned = (float) ($trip['plannedDistanceKm'] ?? $trip['estimatedDistanceKm'] ?? $trip['distanceKm'] ?? 0);
            $actual = $this->actualTripDistanceKm($trip);
            $routes[$routeName]['plannedDistanceKm'] += $planned;
            $routes[$routeName]['actualDistanceKm'] += $actual > 0 ? $actual : $planned;
        }

        $rows = array_values(array_filter(array_map(function (array $route): ?array {
            if ((int) $route['tripCount'] <= 3) {
                return null;
            }

            $planned = (float) $route['plannedDistanceKm'];
            $actual = (float) $route['actualDistanceKm'];
            $variance = $planned > 0 ? (($actual - $planned) / $planned) * 100 : 0.0;

            return [
                'route' => $route['route'],
                'tripCount' => (int) $route['tripCount'],
                'plannedDistanceKm' => round($planned, 1),
                'actualDistanceKm' => round($actual, 1),
                'variancePercent' => round($variance, 1),
                'flagged' => $variance > 15,
            ];
        }, $routes)));
        usort($rows, fn (array $a, array $b): int => ((float) $b['variancePercent']) <=> ((float) $a['variancePercent']));

        return [
            'generatedAt' => now()->toIso8601String(),
            'cacheTtlSeconds' => 600,
            'routes' => $rows,
            'flaggedRoutes' => array_values(array_filter($rows, fn (array $row): bool => (bool) $row['flagged'])),
        ];
    }

    private function tripForecastPayload(): array
    {
        $snapshot = $this->predictiveSnapshot();
        $trips = is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [];
        $windowStart = now()->subDays(60)->startOfDay();
        $counts = array_fill(1, 7, 0);
        $samples = array_fill(1, 7, 0);

        for ($date = $windowStart->copy(); $date->lessThanOrEqualTo(now()); $date->addDay()) {
            $samples[$date->dayOfWeekIso]++;
        }

        foreach ($trips as $trip) {
            $date = $this->parseDate($trip['startedAt'] ?? $trip['endedAt'] ?? $trip['date'] ?? null);
            if ($date === null || $date->lessThan($windowStart)) {
                continue;
            }

            $counts[$date->dayOfWeekIso]++;
        }

        $averages = [];
        for ($day = 1; $day <= 7; $day++) {
            $labelDate = now()->startOfWeek()->addDays($day - 1);
            $average = $samples[$day] > 0 ? round($counts[$day] / $samples[$day], 2) : 0.0;
            $averages[] = [
                'dayOfWeekIso' => $day,
                'label' => $labelDate->format('D'),
                'averageTrips' => $average,
            ];
        }

        $forecast = [];
        for ($offset = 1; $offset <= 7; $offset++) {
            $date = now()->addDays($offset);
            $average = $samples[$date->dayOfWeekIso] > 0 ? $counts[$date->dayOfWeekIso] / $samples[$date->dayOfWeekIso] : 0;
            $forecast[] = [
                'date' => $date->toDateString(),
                'label' => $date->format('D'),
                'forecastTrips' => (int) round($average),
                'averageTrips' => round($average, 2),
            ];
        }

        return [
            'generatedAt' => now()->toIso8601String(),
            'cacheTtlSeconds' => 3600,
            'windowDays' => 60,
            'averagesByDayOfWeek' => $averages,
            'forecast' => $forecast,
        ];
    }

    private function fuelTrendPayload(): array
    {
        $snapshot = $this->predictiveSnapshot();
        $fuel = is_array($snapshot['fuel'] ?? null) ? $snapshot['fuel'] : [];
        $billings = is_array($snapshot['billings'] ?? null) ? $snapshot['billings'] : [];
        $transactions = is_array($fuel['transactions'] ?? null) ? $fuel['transactions'] : [];
        $start = now()->subDays(27)->startOfDay();
        $daily = [];
        for ($date = $start->copy(); $date->lessThanOrEqualTo(now()); $date->addDay()) {
            $daily[$date->toDateString()] = 0.0;
        }

        foreach ([...$transactions, ...$billings] as $row) {
            $date = $this->parseDate($row['dateTime'] ?? $row['date'] ?? $row['issuedAt'] ?? $row['createdAt'] ?? null);
            if ($date === null || ! isset($daily[$date->toDateString()])) {
                continue;
            }

            $daily[$date->toDateString()] += $this->parseMoney($row['fuelCost'] ?? $row['fuelCostEstimate'] ?? $row['cost'] ?? $row['amount'] ?? 0);
        }

        $points = [];
        $keys = array_keys($daily);
        foreach ($keys as $index => $key) {
            $slice = array_slice($daily, max(0, $index - 6), min(7, $index + 1), true);
            $average = array_sum($slice) / max(1, count($slice));
            $points[] = [
                'date' => $key,
                'label' => Carbon::parse($key)->format('M j'),
                'cost' => round($daily[$key], 2),
                'costLabel' => $this->money($daily[$key]),
                'rollingAverage' => round($average, 2),
                'rollingAverageLabel' => $this->money($average),
            ];
        }

        $thisWeek = array_sum(array_slice($daily, -7, 7, true));
        $lastWeek = array_sum(array_slice($daily, -14, 7, true));
        $difference = $thisWeek - $lastWeek;
        $trendPercent = $lastWeek > 0 ? round((abs($difference) / $lastWeek) * 100, 1) : ($thisWeek > 0 ? 100.0 : 0.0);

        return [
            'generatedAt' => now()->toIso8601String(),
            'cacheTtlSeconds' => 600,
            'rollingWindowDays' => 7,
            'thisWeekCost' => round($thisWeek, 2),
            'lastWeekCost' => round($lastWeek, 2),
            'thisWeekLabel' => $this->money($thisWeek),
            'lastWeekLabel' => $this->money($lastWeek),
            'trendDirection' => $difference > 0 ? 'up' : ($difference < 0 ? 'down' : 'flat'),
            'trendPercent' => $trendPercent,
            'sparkline' => array_values(array_slice($points, -14)),
            'points' => $points,
        ];
    }

    private function dashboardSummaryPayload(): array
    {
        $snapshot = $this->cachedSnapshotForDashboardSummary();
        $snapshotUnavailable = (bool) ($snapshot['_snapshotUnavailable'] ?? false);
        unset($snapshot['_snapshotUnavailable']);

        $trips = is_array($snapshot['trips'] ?? null) ? $snapshot['trips'] : [];
        $vehicles = is_array($snapshot['vehicles'] ?? null) ? $snapshot['vehicles'] : [];
        $drivers = is_array($snapshot['drivers'] ?? null) ? $snapshot['drivers'] : [];
        $billings = is_array($snapshot['billings'] ?? null) ? $snapshot['billings'] : [];
        $telemetry = is_array($snapshot['telemetry'] ?? null) ? $snapshot['telemetry'] : [];

        $insights = $this->dashboardInsights($trips, $vehicles, $drivers, $billings, $telemetry);
        $this->storeHumidityBreachNotificationsFromFeedRows();
        $humidityCount = $this->weeklyHumidityAlertCount((int) ($insights['humidityAlertCount'] ?? 0));

        $payload = [
            'generatedAt' => now()->toIso8601String(),
            'cacheTtlSeconds' => 120,
            'monthAtGlance' => $insights['monthAtGlance'],
            'tripsThisWeek' => $insights['tripsThisWeek'],
            'fleetUtilization' => $this->dashboardFleetUtilizationPanel($insights['fleetUtilization'] ?? []),
            'topActiveVehicles' => $this->dashboardTopVehiclesPanel($insights['topActiveVehicles'] ?? []),
            'recentRevenueSummary' => $this->dashboardRevenuePanel($insights['recentRevenueSummary'] ?? []),
            'humidityAlertCount' => [
                'count' => $humidityCount,
                'label' => $humidityCount > 0 ? 'humidity alerts this week' : 'No alerts this week',
                'state' => $humidityCount > 0 ? 'alert' : 'clear',
            ],
            'predictiveMaintenance' => $this->maintenancePredictionsPayload()['topUrgent'] ?? $insights['predictiveMaintenance'],
            'fuelCostTrend' => $insights['fuelCostTrend'],
            'tripVolumeForecast' => $insights['tripVolumeForecast'],
            'idleTimeAlerts' => $insights['idleTimeAlerts'],
            'recentTrips' => array_values(array_map(
                fn (array $trip): array => $this->formatDashboardRecentTrip($trip),
                array_slice($trips, 0, 6),
            )),
        ];

        if ($snapshotUnavailable) {
            $payload['stale'] = true;
            $payload['refreshing'] = true;
            $payload['geotabAvailable'] = false;
            $payload['geotab_available'] = false;
            $payload['geotabReason'] = 'snapshot_unavailable';
            $payload['geotab_reason'] = 'snapshot_unavailable';
            $payload['lastSyncedAt'] = now()->toIso8601String();
        }

        return $payload;
    }

    private function cachedSnapshotForDashboardSummary(): array
    {
        $fresh = Cache::get(self::SNAPSHOT_FRESH_KEY);
        if (is_array($fresh) && $fresh !== []) {
            return $fresh;
        }

        $stale = Cache::get(self::SNAPSHOT_STALE_KEY);
        if (is_array($stale) && $stale !== []) {
            return $stale;
        }

        return [
            ...$this->emptySnapshot(),
            '_snapshotUnavailable' => true,
        ];
    }

    private function dashboardFleetUtilizationPanel(array $utilization): array
    {
        $active = (int) ($utilization['activeVehiclesToday'] ?? 0);
        $total = (int) ($utilization['totalVehicles'] ?? 0);
        $rate = $total > 0 ? (float) ($utilization['rate'] ?? ($active / $total)) : 0.0;
        $percentage = round($rate * 100, 1);

        return [
            'activeVehiclesToday' => $active,
            'totalVehicles' => $total,
            'rate' => round($rate, 4),
            'percentage' => $percentage,
            'percentageLabel' => rtrim(rtrim(number_format($percentage, 1), '0'), '.').'%',
            'activeLabel' => $active.' of '.$total.' vehicles active today',
        ];
    }

    private function dashboardTopVehiclesPanel(array $vehicles): array
    {
        $vehicles = array_values(array_slice($vehicles, 0, 5));

        return array_values(array_map(function (array $vehicle, int $index): array {
            $distance = round((float) ($vehicle['distanceKmToday'] ?? $vehicle['distanceKm'] ?? 0), 2);

            return [
                'rank' => $index + 1,
                'plateNumber' => $this->sanitizeText($vehicle['plate'] ?? $vehicle['vehicle'] ?? '', 'UNKNOWN'),
                'driverFullName' => $this->sanitizeText($vehicle['driver'] ?? '', 'Unassigned'),
                'distanceKmToday' => $distance,
                'distanceLabel' => number_format($distance, 1).' km',
                'status' => $this->sanitizeText($vehicle['status'] ?? '', 'available'),
            ];
        }, $vehicles, array_keys($vehicles)));
    }

    private function dashboardRevenuePanel(array $revenue): array
    {
        $thisWeek = (float) ($revenue['thisWeek'] ?? 0);
        $lastWeek = (float) ($revenue['lastWeek'] ?? 0);
        $difference = $thisWeek - $lastWeek;
        $trend = $difference > 0 ? 'up' : ($difference < 0 ? 'down' : 'flat');
        $trendPercent = $lastWeek > 0 ? round((abs($difference) / $lastWeek) * 100, 1) : ($thisWeek > 0 ? 100.0 : 0.0);

        return [
            'thisWeek' => round($thisWeek, 2),
            'lastWeek' => round($lastWeek, 2),
            'thisWeekLabel' => $this->money($thisWeek),
            'lastWeekLabel' => $this->money($lastWeek),
            'trend' => $trend,
            'trendPercent' => $trendPercent,
            'trendLabel' => $trend === 'flat' ? 'No change' : rtrim(rtrim(number_format($trendPercent, 1), '0'), '.').'% '.$trend,
        ];
    }

    private function formatDashboardRecentTrip(array $trip): array
    {
        $formatted = $this->formatWorkflowTrip($trip);

        return [
            ...$formatted,
            'routeText' => $formatted['routeText'] ?? (($formatted['origin'] ?? 'Trip start').' -> '.($formatted['destination'] ?? 'Trip stop')),
            'routeFallback' => $formatted['routeFallback'] ?? $this->tripCoordinateFallback($formatted),
        ];
    }

    private function tripCoordinateFallback(array $trip): string
    {
        $parts = $this->coordinateParts($trip['startPoint'] ?? null);
        if ($parts !== null) {
            return $this->formatCardinalCoordinate($parts, 'Route coordinates unavailable');
        }

        if (! Schema::hasTable('gps_logs')) {
            return 'Route coordinates unavailable';
        }

        $query = GpsLog::query();
        $tripId = trim((string) ($trip['tripId'] ?? ''));
        $deviceId = trim((string) ($trip['deviceGeotabId'] ?? ''));
        if ($tripId !== '') {
            $query->where('trip_id', $tripId);
        } elseif ($deviceId !== '') {
            $query->where('device_geotab_id', $deviceId);
        } else {
            return 'Route coordinates unavailable';
        }

        $log = $query->orderBy('recorded_at')->first();
        if ($log === null) {
            return 'Route coordinates unavailable';
        }

        return $this->formatCardinalCoordinate([
            'latitude' => (float) $log->latitude,
            'longitude' => (float) $log->longitude,
        ], 'Route coordinates unavailable');
    }

    private function formatCardinalCoordinate(array $parts, string $fallback): string
    {
        $latitude = (float) ($parts['latitude'] ?? 0);
        $longitude = (float) ($parts['longitude'] ?? 0);
        if ($latitude === 0.0 && $longitude === 0.0) {
            return $fallback;
        }

        return number_format(abs($latitude), 4)."\u{00B0}".($latitude >= 0 ? 'N' : 'S')
            .', '
            .number_format(abs($longitude), 4)."\u{00B0}".($longitude >= 0 ? 'E' : 'W');
    }

    private function weeklyHumidityAlertCount(int $snapshotFallback): int
    {
        $weekStart = now()->startOfWeek();
        $weekEnd = now()->endOfWeek();

        if (Schema::hasTable('humidity_logs') && Schema::hasColumn('humidity_logs', 'alert_triggered')) {
            $timestampColumn = Schema::hasColumn('humidity_logs', 'recorded_timestamp')
                ? 'recorded_timestamp'
                : (Schema::hasColumn('humidity_logs', 'recorded_at') ? 'recorded_at' : null);

            if ($timestampColumn !== null) {
                return (int) DB::table('humidity_logs')
                    ->where('alert_triggered', true)
                    ->whereBetween($timestampColumn, [$weekStart, $weekEnd])
                    ->count();
            }
        }

        if (! Schema::hasTable('geotab_feed_rows')) {
            return $snapshotFallback;
        }

        return GeotabFeedRow::query()
            ->whereBetween('recorded_at', [$weekStart, $weekEnd])
            ->get()
            ->filter(function (GeotabFeedRow $row): bool {
                $payload = is_array($row->payload) ? $row->payload : [];

                return data_get($payload, 'alert_triggered') === true
                    || data_get($payload, 'alertTriggered') === true
                    || data_get($payload, 'alerts.humidityAlert') === true
                    || ($row->diagnostic_alias === 'relativeHumidity' && (float) data_get($payload, 'data', data_get($payload, 'value', 0)) >= 85);
            })
            ->count();
    }

    private function dashboardInsights(
        array $trips,
        array $vehicles,
        array $drivers,
        array $billings,
        array $telemetryOverview,
    ): array {
        $startToday = now()->startOfDay();
        $monthStart = now()->startOfMonth();
        $weekStart = now()->startOfWeek();
        $lastWeekStart = now()->subWeek()->startOfWeek();
        $lastWeekEnd = now()->subWeek()->endOfWeek();

        $tripsByDay = [];
        for ($day = 6; $day >= 0; $day--) {
            $date = now()->subDays($day);
            $tripsByDay[$date->toDateString()] = [
                'date' => $date->toDateString(),
                'label' => $date->format('D'),
                'count' => 0,
            ];
        }

        $activeVehiclesToday = [];
        $distanceTodayByVehicle = [];
        $monthTripsCompleted = 0;
        $monthKm = 0.0;
        $monthOnTime = 0;
        $monthTimedTrips = 0;
        $completedStatus = ['completed', 'delivered', 'done'];
        $tripsByWeekday = array_fill(1, 7, []);
        foreach ($trips as $trip) {
            $date = $this->parseDate($trip['startedAt'] ?? $trip['endedAt'] ?? $trip['date'] ?? null);
            if ($date !== null && isset($tripsByDay[$date->toDateString()])) {
                $tripsByDay[$date->toDateString()]['count']++;
            }

            if ($date !== null) {
                $tripsByWeekday[$date->dayOfWeekIso][] = $trip;
            }

            if ($date !== null && $date->greaterThanOrEqualTo($startToday)) {
                $vehicle = trim((string) ($trip['vehicle'] ?? ''));
                if ($vehicle !== '') {
                    $activeVehiclesToday[$vehicle] = true;
                    $distanceTodayByVehicle[$vehicle] = ($distanceTodayByVehicle[$vehicle] ?? 0)
                        + (float) ($trip['distanceKm'] ?? 0);
                }
            }

            if ($date !== null && $date->greaterThanOrEqualTo($monthStart)) {
                $status = strtolower((string) ($trip['status'] ?? ''));
                if (in_array($status, $completedStatus, true)) {
                    $monthTripsCompleted++;
                }

                $monthKm += (float) ($trip['distanceKm'] ?? 0);
                $arrivalState = strtolower((string) ($trip['arrivalState'] ?? $trip['slaState'] ?? ''));
                if ($arrivalState !== '') {
                    $monthTimedTrips++;
                    if (! str_contains($arrivalState, 'late') && ! str_contains($arrivalState, 'delay')) {
                        $monthOnTime++;
                    }
                }
            }
        }

        $driverByVehicle = [];
        foreach ($drivers as $driver) {
            $vehicle = trim((string) ($driver['assignedVehicle'] ?? ''));
            if ($vehicle !== '') {
                $driverByVehicle[$vehicle] = (string) ($driver['name'] ?? 'N/A');
            }
        }

        $topActiveVehicles = array_map(function (array $vehicle) use ($distanceTodayByVehicle, $driverByVehicle): array {
            $plate = (string) ($vehicle['plate'] ?? 'Unknown');

            return [
                'vehicle' => $plate,
                'plate' => $plate,
                'driver' => $vehicle['driver'] ?? $driverByVehicle[$plate] ?? 'N/A',
                'distanceKmToday' => round((float) ($distanceTodayByVehicle[$plate] ?? 0), 2),
                'status' => $vehicle['status'] ?? 'available',
            ];
        }, $vehicles);
        usort($topActiveVehicles, fn (array $a, array $b): int => $b['distanceKmToday'] <=> $a['distanceKmToday']);

        $thisWeekRevenue = 0.0;
        $lastWeekRevenue = 0.0;
        $monthInvoiced = 0.0;
        $fuelByWeek = [];
        for ($week = 7; $week >= 0; $week--) {
            $start = now()->subWeeks($week)->startOfWeek();
            $key = $start->toDateString();
            $fuelByWeek[$key] = [
                'weekStart' => $key,
                'label' => $start->format('M j'),
                'cost' => 0.0,
                'costLabel' => $this->money(0),
            ];
        }

        foreach ($billings as $billing) {
            $date = $this->parseDate($billing['date'] ?? $billing['issuedAt'] ?? $billing['createdAt'] ?? null);
            $amount = $this->parseMoney($billing['amount'] ?? $billing['total'] ?? 0);
            if ($date !== null && $date->greaterThanOrEqualTo($weekStart)) {
                $thisWeekRevenue += $amount;
            } elseif ($date !== null && $date->betweenIncluded($lastWeekStart, $lastWeekEnd)) {
                $lastWeekRevenue += $amount;
            }

            if ($date !== null && $date->greaterThanOrEqualTo($monthStart)) {
                $monthInvoiced += $amount;
            }

            if ($date !== null) {
                $weekKey = $date->copy()->startOfWeek()->toDateString();
                if (isset($fuelByWeek[$weekKey])) {
                    $fuelByWeek[$weekKey]['cost'] += $this->parseMoney($billing['fuelCost'] ?? $billing['fuelCostEstimate'] ?? 0);
                }
            }
        }

        foreach ($fuelByWeek as $key => $row) {
            $fuelByWeek[$key]['cost'] = round((float) $row['cost'], 2);
            $fuelByWeek[$key]['costLabel'] = $this->money((float) $row['cost']);
        }

        return [
            'monthAtGlance' => [
                'tripsCompleted' => $monthTripsCompleted,
                'kmDriven' => round($monthKm, 1),
                'kmDrivenLabel' => number_format($monthKm, 1).' km',
                'onTimeDeliveryRate' => $monthTimedTrips > 0 ? round($monthOnTime / $monthTimedTrips, 4) : 0,
                'onTimeDeliveryLabel' => $monthTimedTrips > 0 ? round(($monthOnTime / $monthTimedTrips) * 100).'%' : 'N/A',
                'totalInvoiced' => round($monthInvoiced, 2),
                'totalInvoicedLabel' => $this->money($monthInvoiced),
            ],
            'tripsThisWeek' => array_values($tripsByDay),
            'fleetUtilization' => [
                'activeVehiclesToday' => count($activeVehiclesToday),
                'totalVehicles' => count($vehicles),
                'rate' => count($vehicles) > 0 ? round(count($activeVehiclesToday) / count($vehicles), 4) : 0,
            ],
            'topActiveVehicles' => array_slice($topActiveVehicles, 0, 5),
            'recentRevenueSummary' => [
                'thisWeek' => round($thisWeekRevenue, 2),
                'lastWeek' => round($lastWeekRevenue, 2),
                'thisWeekLabel' => $this->money($thisWeekRevenue),
                'lastWeekLabel' => $this->money($lastWeekRevenue),
                'trend' => $thisWeekRevenue > $lastWeekRevenue ? 'up' : ($thisWeekRevenue < $lastWeekRevenue ? 'down' : 'flat'),
            ],
            'humidityAlertCount' => (int) ($telemetryOverview['humidityAlertAssets'] ?? 0),
            'predictiveMaintenance' => $this->predictiveMaintenanceRows($vehicles),
            'fuelCostTrend' => array_values($fuelByWeek),
            'tripVolumeForecast' => $this->tripVolumeForecastRows($tripsByWeekday),
            'idleTimeAlerts' => $this->idleVehicleAlertRows($vehicles),
        ];
    }

    private function predictiveMaintenanceRows(array $vehicles): array
    {
        $history = $this->maintenanceHistoryTableAvailable()
            ? MaintenanceHistory::query()->orderByDesc('recorded_at')->get()->groupBy(fn (MaintenanceHistory $row): string => (string) ($row->vehicle_plate ?: $row->vehicle_geotab_id ?: 'Unknown'))
            : collect();

        $rows = [];
        foreach ($vehicles as $vehicle) {
            $plate = $this->sanitizeText($vehicle['plate'] ?? $vehicle['vehicle'] ?? '', 'Unknown');
            $records = $history->get($plate, collect());
            $last = $records->first();
            $avgDays = 90;
            if ($records->count() >= 2) {
                $dates = $records->pluck('recorded_at')->filter()->values();
                $gaps = [];
                for ($index = 0; $index < $dates->count() - 1; $index++) {
                    $gaps[] = abs(Carbon::parse($dates[$index])->diffInDays(Carbon::parse($dates[$index + 1])));
                }
                $avgDays = max(14, (int) round(array_sum($gaps) / max(count($gaps), 1)));
            }

            $lastDate = $last?->recorded_at ? Carbon::parse($last->recorded_at) : now()->subDays(45);
            $nextDue = $last?->next_due_at ? Carbon::parse($last->next_due_at) : $lastDate->copy()->addDays($avgDays);
            $daysUntil = now()->startOfDay()->diffInDays($nextDue->copy()->startOfDay(), false);
            $rows[] = [
                'vehicle' => $plate,
                'plate' => $plate,
                'lastServiceAt' => $lastDate->toDateString(),
                'predictedNextDueAt' => $nextDue->toDateString(),
                'daysUntilDue' => $daysUntil,
                'state' => $daysUntil < 0 ? 'overdue' : ($daysUntil <= 14 ? 'due_soon' : 'normal'),
                'label' => $daysUntil < 0 ? abs($daysUntil).' days overdue' : $daysUntil.' days remaining',
            ];
        }

        usort($rows, fn (array $a, array $b): int => ((int) $a['daysUntilDue']) <=> ((int) $b['daysUntilDue']));

        return array_slice($rows, 0, 5);
    }

    private function tripVolumeForecastRows(array $tripsByWeekday): array
    {
        $rows = [];
        for ($offset = 1; $offset <= 7; $offset++) {
            $date = now()->addDays($offset);
            $samples = $tripsByWeekday[$date->dayOfWeekIso] ?? [];
            $forecast = count($samples) > 0 ? (int) round(count($samples) / max(1, ceil(count($samples) / 4))) : 0;
            $rows[] = [
                'date' => $date->toDateString(),
                'label' => $date->format('D'),
                'forecastTrips' => $forecast,
            ];
        }

        return $rows;
    }

    private function idleVehicleAlertRows(array $vehicles): array
    {
        $threshold = max(1, (int) $this->systemSettingsValue('idle_time_alert_threshold_minutes', 30));

        return array_values(array_slice(array_filter(array_map(function (array $vehicle) use ($threshold): ?array {
            $idleMinutes = (int) ($vehicle['idleMinutes24h'] ?? $vehicle['idleMinutes'] ?? 0);
            $isIdleNow = (($vehicle['ignitionOn'] ?? false) === true || strtolower((string) ($vehicle['status'] ?? '')) === 'idle')
                && ((float) ($vehicle['speed'] ?? 0)) <= 1;
            if ($idleMinutes < $threshold && ! $isIdleNow) {
                return null;
            }
            $displayMinutes = max($idleMinutes, $isIdleNow ? $threshold : 0);

            return [
                'vehicle' => $this->sanitizeText($vehicle['plate'] ?? $vehicle['vehicle'] ?? '', 'Unknown'),
                'driver' => $this->sanitizeText($vehicle['driver'] ?? '', 'Unassigned'),
                'idleMinutes' => $displayMinutes,
                'label' => $displayMinutes.' min idle',
            ];
        }, $vehicles)), 0, 5));
    }

    private function analyticsInsights(
        array $trips,
        array $vehicles,
        array $drivers,
        array $maintenance,
        array $faults,
    ): array {
        $monthStart = now()->startOfMonth();
        $driverStats = [];
        $driverResolver = $this->driverNameResolver($drivers);
        foreach ($drivers as $driver) {
            $name = $this->resolveAnalyticsDriverName($driver['name'] ?? $driver['driverId'] ?? null, $driverResolver);
            $driverStats[$name] = [
                'driver' => $name,
                'totalTrips' => 0,
                'totalKm' => 0.0,
                'onTimeTrips' => 0,
                'timedTrips' => 0,
                'onTimeRate' => 0,
                'onTimeLabel' => 'N/A',
            ];
        }

        $routeStats = [];
        foreach ($trips as $trip) {
            $date = $this->parseDate($trip['startedAt'] ?? $trip['endedAt'] ?? $trip['date'] ?? null);
            $driver = $this->resolveAnalyticsDriverName($trip['driver'] ?? $trip['driverName'] ?? $trip['driverId'] ?? null, $driverResolver);
            $driverStats[$driver] ??= [
                'driver' => $driver,
                'totalTrips' => 0,
                'totalKm' => 0.0,
                'onTimeTrips' => 0,
                'timedTrips' => 0,
                'onTimeRate' => 0,
                'onTimeLabel' => 'N/A',
            ];

            if ($date === null || $date->greaterThanOrEqualTo($monthStart)) {
                $driverStats[$driver]['totalTrips']++;
                $driverStats[$driver]['totalKm'] += (float) ($trip['distanceKm'] ?? 0);
                $arrivalState = strtolower((string) ($trip['arrivalState'] ?? $trip['slaState'] ?? ''));
                if ($arrivalState !== '') {
                    $driverStats[$driver]['timedTrips']++;
                    if (! str_contains($arrivalState, 'late') && ! str_contains($arrivalState, 'delay')) {
                        $driverStats[$driver]['onTimeTrips']++;
                    }
                }
            }

            $routeName = $this->sanitizeText($trip['routeName'] ?? $trip['routeText'] ?? '', '');
            if ($routeName !== '') {
                $routeStats[$routeName] ??= [
                    'route' => $routeName,
                    'tripCount' => 0,
                    'plannedDistanceKm' => 0.0,
                    'actualDistanceKm' => 0.0,
                ];
                $routeStats[$routeName]['tripCount']++;
                $actual = (float) ($trip['distanceKm'] ?? 0);
                $planned = (float) ($trip['plannedDistanceKm'] ?? $trip['distanceKm'] ?? 0);
                $routeStats[$routeName]['actualDistanceKm'] += $actual;
                $routeStats[$routeName]['plannedDistanceKm'] += $planned;
            }
        }

        foreach ($driverStats as $name => $row) {
            $rate = (int) $row['timedTrips'] > 0 ? (float) $row['onTimeTrips'] / (float) $row['timedTrips'] : 0;
            $driverStats[$name]['totalKm'] = round((float) $row['totalKm'], 1);
            $driverStats[$name]['onTimeRate'] = round($rate, 4);
            $driverStats[$name]['onTimeLabel'] = (int) $row['timedTrips'] > 0 ? round($rate * 100).'%' : 'N/A';
        }
        usort($driverStats, fn (array $a, array $b): int => ((float) $b['onTimeRate'] <=> (float) $a['onTimeRate']) ?: ((int) $b['totalTrips'] <=> (int) $a['totalTrips']));

        $faultsByVehicle = [];
        foreach ($faults as $fault) {
            $plate = $this->sanitizeText($fault['vehicle'] ?? $fault['plate'] ?? '', 'Unknown');
            $faultsByVehicle[$plate] = ($faultsByVehicle[$plate] ?? 0) + 1;
        }

        $maintenanceByVehicle = [];
        foreach ($maintenance as $record) {
            $plate = $this->sanitizeText($record['vehicle'] ?? $record['plate'] ?? '', 'Unknown');
            $date = $this->parseDate($record['dateTime'] ?? $record['recordedAt'] ?? null);
            if ($date !== null && (! isset($maintenanceByVehicle[$plate]) || $date->greaterThan($maintenanceByVehicle[$plate]))) {
                $maintenanceByVehicle[$plate] = $date;
            }
        }

        $riskRows = array_map(function (array $vehicle) use ($faultsByVehicle, $maintenanceByVehicle): array {
            $plate = $this->sanitizeText($vehicle['plate'] ?? $vehicle['vehicle'] ?? '', 'Unknown');
            $last = $maintenanceByVehicle[$plate] ?? now()->subDays(90);
            $daysSince = max(0, (int) $last->diffInDays(now()));
            $faultCount = (int) ($faultsByVehicle[$plate] ?? 0);
            $kmSince = (float) ($vehicle['distanceSinceServiceKm'] ?? $vehicle['odometerSinceServiceKm'] ?? 0);
            $score = min(100, (int) round(($daysSince / 120) * 45 + min(30, $faultCount * 10) + min(25, $kmSince / 400)));

            return [
                'vehicle' => $plate,
                'riskScore' => $score,
                'riskLevel' => $score >= 70 ? 'high' : ($score >= 40 ? 'medium' : 'low'),
                'daysSinceLastMaintenance' => $daysSince,
                'faultCodeCount' => $faultCount,
                'kmSinceLastService' => round($kmSince, 1),
            ];
        }, $vehicles);
        usort($riskRows, fn (array $a, array $b): int => ((int) $b['riskScore']) <=> ((int) $a['riskScore']));

        $routeRows = array_values(array_filter(array_map(function (array $route): ?array {
            if ((int) $route['tripCount'] <= 3) {
                return null;
            }

            $planned = (float) $route['plannedDistanceKm'];
            $actual = (float) $route['actualDistanceKm'];
            $variance = $planned > 0 ? (($actual - $planned) / $planned) * 100 : 0;

            return [
                'route' => $route['route'],
                'tripCount' => (int) $route['tripCount'],
                'plannedDistanceKm' => round($planned, 1),
                'actualDistanceKm' => round($actual, 1),
                'variancePercent' => round($variance, 1),
                'flagged' => $variance > 15,
            ];
        }, $routeStats)));
        usort($routeRows, fn (array $a, array $b): int => ((float) $b['variancePercent']) <=> ((float) $a['variancePercent']));

        return [
            'driverPerformance' => array_slice(array_values($driverStats), 0, 10),
            'vehicleHealthRisk' => array_slice($riskRows, 0, 10),
            'routeEfficiency' => array_slice($routeRows, 0, 10),
        ];
    }

    private function emptyDriverPerformanceRow(string $name): array
    {
        return [
            'driver' => $name,
            'totalTrips' => 0,
            'totalKm' => 0.0,
            'onTimeTrips' => 0,
            'timedTrips' => 0,
            'onTimeRate' => 0.0,
            'onTimeLabel' => 'N/A',
            'score' => 0.0,
        ];
    }

    private function maintenanceRecordOdometerKm(MaintenanceHistory $row): ?float
    {
        $meta = is_array($row->meta) ? $row->meta : [];
        foreach (['odometerKm', 'odometer_km', 'currentKm', 'current_km', 'mileageKm', 'mileage_km'] as $key) {
            if (isset($meta[$key]) && is_numeric($meta[$key])) {
                return (float) $meta[$key];
            }
        }

        return null;
    }

    private function vehicleOdometerKm(array $vehicle): ?float
    {
        foreach ([
            'odometerKm',
            'currentKm',
            'mileageKm',
            'diagnostics.rawOdometer.value',
            'diagnostics.odometer.value',
        ] as $key) {
            $value = str_contains($key, '.') ? data_get($vehicle, $key) : ($vehicle[$key] ?? null);
            if (is_numeric($value)) {
                return (float) $value;
            }
        }

        return null;
    }

    private function actualTripDistanceKm(array $trip): float
    {
        $explicit = $trip['actualDistanceKm'] ?? $trip['distanceKm'] ?? null;
        $tripId = trim((string) ($trip['tripId'] ?? ''));
        if ($tripId !== '' && Schema::hasTable('gps_logs')) {
            $logs = GpsLog::query()
                ->where('trip_id', $tripId)
                ->orderBy('recorded_at')
                ->get(['latitude', 'longitude']);
            if ($logs->count() >= 2) {
                return $this->gpsLogDistanceKm($logs);
            }
        }

        return is_numeric($explicit) ? (float) $explicit : 0.0;
    }

    private function gpsLogDistanceKm(mixed $logs): float
    {
        $distance = 0.0;
        $previous = null;
        foreach ($logs as $log) {
            $current = [
                'latitude' => (float) $log->latitude,
                'longitude' => (float) $log->longitude,
            ];
            if ($previous !== null) {
                $distance += $this->haversineKm($previous, $current);
            }
            $previous = $current;
        }

        return round($distance, 2);
    }

    private function haversineKm(array $from, array $to): float
    {
        $earthRadiusKm = 6371.0;
        $lat1 = deg2rad((float) $from['latitude']);
        $lat2 = deg2rad((float) $to['latitude']);
        $deltaLat = deg2rad((float) $to['latitude'] - (float) $from['latitude']);
        $deltaLng = deg2rad((float) $to['longitude'] - (float) $from['longitude']);
        $a = sin($deltaLat / 2) ** 2 + cos($lat1) * cos($lat2) * (sin($deltaLng / 2) ** 2);

        return $earthRadiusKm * 2 * atan2(sqrt($a), sqrt(1 - $a));
    }

    private function estimateTripAmount(float $distanceKm): float
    {
        if ($distanceKm <= 0) {
            return 0;
        }

        return max(2500, round($distanceKm * (float) $this->systemSettingsValue('base_delivery_charge_per_km', 65), 2));
    }

    private function money(float $amount, bool $negative = false): string
    {
        $prefix = $negative ? '-PHP ' : 'PHP ';

        return $prefix.number_format(abs($amount), 2);
    }

    private function parseMoney(mixed $value): float
    {
        return (float) preg_replace('/[^0-9.\-]/', '', (string) $value);
    }

    private function normalizeDateString(mixed $value): string
    {
        if (is_string($value) && preg_match('/^\d{4}-\d{2}-\d{2}$/', $value) === 1) {
            return $value;
        }

        try {
            return Carbon::parse((string) $value)->toDateString();
        } catch (\Throwable) {
            return now()->toDateString();
        }
    }

    private function displayTripId(string $geotabId, string $prefix): string
    {
        $suffix = strtoupper(substr(preg_replace('/[^A-Za-z0-9]/', '', $geotabId), -6));

        return $prefix.'-'.($suffix !== '' ? $suffix : 'SYNCED');
    }

    private function secondsToMinutes(mixed $seconds): int
    {
        if (! is_numeric($seconds)) {
            return 0;
        }

        return (int) round(((float) $seconds) / 60);
    }

    private function geotabDurationToMinutes(mixed $value): int
    {
        if (is_array($value)) {
            if (isset($value['milliseconds']) && is_numeric($value['milliseconds'])) {
                return $this->secondsToMinutes(((float) $value['milliseconds']) / 1000);
            }

            if (isset($value['seconds']) && is_numeric($value['seconds'])) {
                return $this->secondsToMinutes($value['seconds']);
            }

            if (isset($value['ticks']) && is_numeric($value['ticks'])) {
                return $this->secondsToMinutes(((float) $value['ticks']) / 10000000);
            }

            $value = $value['value'] ?? null;
        }

        if ($value === null || trim((string) $value) === '') {
            return 0;
        }

        if (is_numeric($value)) {
            return $this->secondsToMinutes(((float) $value) / 1000);
        }

        $duration = trim((string) $value);
        if (preg_match('/^(?:(\d+)\.)?(\d{1,3}):(\d{2}):(\d{2})(?:\.\d+)?$/', $duration, $matches) === 1) {
            $days = (int) ($matches[1] ?? 0);
            $hours = (int) $matches[2];
            $minutes = (int) $matches[3];
            $seconds = (int) $matches[4];

            return $this->secondsToMinutes(($days * 86400) + ($hours * 3600) + ($minutes * 60) + $seconds);
        }

        if (preg_match('/^P(?:T)?(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$/i', $duration, $matches) === 1) {
            $hours = (float) ($matches[1] ?? 0);
            $minutes = (float) ($matches[2] ?? 0);
            $seconds = (float) ($matches[3] ?? 0);

            return $this->secondsToMinutes(($hours * 3600) + ($minutes * 60) + $seconds);
        }

        return 0;
    }

    private function fuelCapacityForFillUp(array $fillUp): ?float
    {
        $capacity = data_get($fillUp, 'tankCapacity.capacity');
        if ($capacity === null) {
            $capacity = data_get($fillUp, 'tankCapacity.value');
        }

        return $capacity !== null ? round((float) $capacity, 2) : null;
    }

    private function tripCustomerLabel(array $trip, ?string $destinationAddress = null, ?string $destinationZone = null): string
    {
        $zoneName = trim((string) data_get($trip, 'stopZone.name', ''));
        if ($zoneName !== '') {
            return $zoneName;
        }

        if ($destinationZone !== null && trim($destinationZone) !== '') {
            return trim($destinationZone);
        }

        if ($destinationAddress !== null && trim($destinationAddress) !== '') {
            return trim($destinationAddress);
        }

        $driverName = $this->userDisplayName(data_get($trip, 'driver'));

        return $driverName !== '' ? 'Trip for '.$driverName : 'Geotab Trip';
    }

    private function findStatusByDriver(array $statusList, string $driverId, string $driverName): array
    {
        foreach ($statusList as $status) {
            $statusDriver = data_get($status, 'driver');
            if ($driverId !== '' && $this->idFromValue($statusDriver) === $driverId) {
                return $status;
            }

            if ($driverName !== '' && $this->userDisplayName($statusDriver) === $driverName) {
                return $status;
            }
        }

        return [];
    }
}
