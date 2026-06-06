<?php

use App\Models\ClientVehicleAssignment;
use App\Models\FleetClient;
use App\Models\FleetRoute;
use App\Models\FleetZone;
use App\Models\GeotabWriteJob;
use App\Models\ManualDriver;
use App\Models\ManualVehicle;
use App\Models\NotificationHistory;
use App\Models\SystemSetting;
use App\Services\GeotabService;
use App\Services\GeotabWriteBackService;
use App\Services\RealtimeFleetEventBroadcaster;
use Database\Seeders\PioneerOperatingZonesSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Cache;

uses(RefreshDatabase::class);

beforeEach(function () {
    Cache::flush();
    Carbon::setTestNow();
});

test('manual driver create stages a geotab writeback approval job without storing password', function () {
    $this->postJson('/api/fleet/drivers/manual', [
        'name' => 'Test Driver',
        'email' => 'test.driver@example.test',
        'license' => 'N01-12345',
        'phone' => '09170000000',
    ])
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'local_modified');

    expect(GeotabWriteJob::query()->count())->toBe(0);

    $this->postJson('/api/fleet/drivers/manual/1/push-geotab', ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewOnly', true)
        ->assertJsonPath('data.preview.entity.isDriver', true);

    expect(GeotabWriteJob::query()->count())->toBe(0);

    $this->postJson('/api/fleet/drivers/manual/1/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    $job = GeotabWriteJob::query()->first();
    expect($job)->not->toBeNull()
        ->and($job->action)->toBe('driver.create')
        ->and($job->status)->toBe('pending_approval')
        ->and(data_get($job->payload, 'entity.isDriver'))->toBeTrue()
        ->and(data_get($job->payload, 'entity.password'))->toBeNull()
        ->and(data_get($job->preview_payload, 'entityType'))->toBe('Driver')
        ->and(data_get($job->preview_payload, 'rows.0.before'))->toBe('Not in GeoTab');

    $driver = ManualDriver::query()->first();
    expect(data_get($driver->meta, 'pendingWriteJobId'))->toBe((string) $job->id);

    $writeBackEvents = app(RealtimeFleetEventBroadcaster::class)->recentEvents('writeback');
    expect($writeBackEvents)->not->toBeEmpty()
        ->and(data_get($writeBackEvents[array_key_last($writeBackEvents)], 'data.job.status'))->toBe('pending_approval')
        ->and(data_get($writeBackEvents[array_key_last($writeBackEvents)], 'data.job.syncLabel'))->toBe('GeoTab: Push awaiting approval');
});

test('writeback approval center payload includes stored preview and rejection is actionable', function () {
    $this->postJson('/api/fleet/drivers/manual', [
        'name' => 'Rejected Driver',
        'email' => 'rejected.driver@example.test',
    ])->assertOk();

    $this->postJson('/api/fleet/drivers/manual/1/push-geotab')->assertOk();

    $job = GeotabWriteJob::query()->firstOrFail();

    $this->getJson('/api/fleet/geotab/writeback/jobs')
        ->assertOk()
        ->assertJsonPath('data.0.previewPayload.entityType', 'Driver')
        ->assertJsonPath('data.0.previewPayload.rows.0.before', 'Not in GeoTab');

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/cancel')
        ->assertStatus(422);

    $unreadBeforeRejection = NotificationHistory::query()->whereNull('read_at')->count();

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/cancel', [
        'reason' => 'License number is missing.',
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'rejected')
        ->assertJsonPath('data.lastError', 'License number is missing.');

    $driver = ManualDriver::query()->firstOrFail();
    $notification = NotificationHistory::query()
        ->where('title', 'GeoTab Push Rejected')
        ->latest('id')
        ->first();
    $event = app(RealtimeFleetEventBroadcaster::class)->latestEvent('notification');

    expect($driver->sync_status)->toBe('local_modified')
        ->and($driver->pending_write_job_id)->toBeNull()
        ->and($driver->sync_error)->toBe('License number is missing.')
        ->and($notification)->not->toBeNull()
        ->and($notification->message)->toContain('License number is missing.')
        ->and(data_get($notification->payload, 'reason'))->toBe('License number is missing.')
        ->and($event)->not->toBeNull()
        ->and($event['event'])->toBe('notification')
        ->and(data_get($event, 'data.notification.id'))->toBe($notification->notification_id)
        ->and(data_get($event, 'data.notification.title'))->toBe('GeoTab Push Rejected')
        ->and(data_get($event, 'data.notification.message'))->toContain('License number is missing.')
        ->and(data_get($event, 'data.unreadCount'))->toBe($unreadBeforeRejection + 1);
});

test('pending writeback job can be deleted without executing a GeoTab change', function () {
    $this->postJson('/api/fleet/drivers/manual', [
        'name' => 'Discarded Driver Push',
        'email' => 'discarded.driver@example.test',
    ])->assertOk();

    $this->postJson('/api/fleet/drivers/manual/1/push-geotab')->assertOk();
    $job = GeotabWriteJob::query()->firstOrFail();

    $this->deleteJson('/api/fleet/geotab/writeback/jobs/'.$job->id)
        ->assertOk()
        ->assertJsonPath('data.deleted', true);

    $driver = ManualDriver::query()->firstOrFail();
    expect(GeotabWriteJob::query()->whereKey($job->id)->exists())->toBeFalse()
        ->and($driver->sync_status)->toBe('local_modified')
        ->and($driver->pending_write_job_id)->toBeNull()
        ->and($driver->sync_error)->toBeNull();
});

test('driver vehicle assignment stages one grouped geotab writeback with shared preview', function () {
    $vehicle = ManualVehicle::query()->create([
        'plate_number' => 'PTC-101',
        'vehicle_type' => 'Drop-side Truck',
        'fuel_type' => 'Diesel',
        'cargo_capacity_kg' => 4500,
        'geotab_device_id' => 'device-101',
        'registration_expiry_date' => now()->addYear()->toDateString(),
        'geotab_snapshot' => ['entity' => ['id' => 'device-101', 'name' => 'PTC-OLD']],
        'sync_status' => 'synced',
    ]);
    $driver = ManualDriver::query()->create([
        'name' => 'Assigned Driver',
        'email' => 'assigned.driver@example.test',
        'assigned_vehicle_plate' => 'PTC-101',
        'meta' => ['geotabUserId' => 'user-101'],
        'geotab_snapshot' => ['entity' => ['id' => 'user-101', 'name' => 'Old Driver']],
        'sync_status' => 'local_modified',
    ]);

    $this->postJson('/api/fleet/drivers/manual/'.$driver->id.'/push-geotab', ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewPayload.isGrouped', true)
        ->assertJsonPath('data.previewPayload.groups.0.entityType', 'Driver')
        ->assertJsonPath('data.previewPayload.groups.1.entityType', 'Vehicle');

    expect(GeotabWriteJob::query()->count())->toBe(0);

    $this->postJson('/api/fleet/drivers/manual/'.$driver->id.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    $job = GeotabWriteJob::query()->firstOrFail();
    expect($job->action)->toBe('group.driver_vehicle_assignment')
        ->and($job->local_type)->toBe('grouped_writeback')
        ->and(data_get($job->preview_payload, 'isGrouped'))->toBeTrue()
        ->and(data_get($job->payload, 'operations'))->toHaveCount(2)
        ->and($driver->refresh()->pending_write_job_id)->toBe($job->id)
        ->and($vehicle->refresh()->pending_write_job_id)->toBe($job->id);
});

test('geotab push preview reports duplicate pending jobs for the same entity', function () {
    $driver = ManualDriver::query()->create([
        'name' => 'Duplicate Driver',
        'email' => 'duplicate.driver@example.test',
        'license' => 'N88-77777',
        'sync_status' => 'local_modified',
    ]);

    $this->postJson('/api/fleet/drivers/manual/'.$driver->id.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    $this->postJson('/api/fleet/drivers/manual/'.$driver->id.'/push-geotab', ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewOnly', true)
        ->assertJsonPath('data.hasPendingGeotabPush', true)
        ->assertJsonPath('data.pendingGeotabPush.status', 'pending_approval');
});

test('grouped driver vehicle assignment processes in order and syncs both local records', function () {
    $fake = new class extends GeotabService
    {
        public array $set = [];

        public function setEntity(string $typeName, array $entity): void
        {
            $this->set[] = compact('typeName', 'entity');
        }
    };
    app()->instance(GeotabService::class, $fake);

    $vehicle = ManualVehicle::query()->create([
        'plate_number' => 'PTC-102',
        'vehicle_type' => 'Drop-side Truck',
        'fuel_type' => 'Diesel',
        'cargo_capacity_kg' => 4500,
        'geotab_device_id' => 'device-102',
        'registration_expiry_date' => now()->addYear()->toDateString(),
        'geotab_snapshot' => ['entity' => ['id' => 'device-102', 'name' => 'PTC-OLD']],
        'sync_status' => 'synced',
    ]);
    $driver = ManualDriver::query()->create([
        'name' => 'Grouped Driver',
        'email' => 'grouped.driver@example.test',
        'assigned_vehicle_plate' => 'PTC-102',
        'meta' => ['geotabUserId' => 'user-102'],
        'geotab_snapshot' => ['entity' => ['id' => 'user-102', 'name' => 'Old Driver']],
        'sync_status' => 'local_modified',
    ]);

    $this->postJson('/api/fleet/drivers/manual/'.$driver->id.'/push-geotab')->assertOk();
    $job = GeotabWriteJob::query()->firstOrFail();

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/approve')
        ->assertOk()
        ->assertJsonPath('data.status', 'succeeded')
        ->assertJsonPath('data.result.typeName', 'GroupedWriteBack');

    expect(array_column($fake->set, 'typeName'))->toBe(['User', 'Device'])
        ->and($driver->refresh()->sync_status)->toBe('synced')
        ->and($vehicle->refresh()->sync_status)->toBe('synced')
        ->and($driver->pending_write_job_id)->toBeNull()
        ->and($vehicle->pending_write_job_id)->toBeNull();
});

test('grouped driver vehicle assignment rolls back completed operations if a later operation fails', function () {
    $fake = new class extends GeotabService
    {
        public array $set = [];

        public function setEntity(string $typeName, array $entity): void
        {
            $this->set[] = compact('typeName', 'entity');
            if ($typeName === 'Device') {
                throw new RuntimeException('Device update failed.');
            }
        }
    };
    app()->instance(GeotabService::class, $fake);

    $vehicle = ManualVehicle::query()->create([
        'plate_number' => 'PTC-103',
        'vehicle_type' => 'Drop-side Truck',
        'fuel_type' => 'Diesel',
        'cargo_capacity_kg' => 4500,
        'geotab_device_id' => 'device-103',
        'registration_expiry_date' => now()->addYear()->toDateString(),
        'geotab_snapshot' => ['entity' => ['id' => 'device-103', 'name' => 'PTC-OLD']],
        'sync_status' => 'synced',
    ]);
    $driver = ManualDriver::query()->create([
        'name' => 'Rollback Driver',
        'email' => 'rollback.driver@example.test',
        'assigned_vehicle_plate' => 'PTC-103',
        'meta' => ['geotabUserId' => 'user-103'],
        'geotab_snapshot' => ['entity' => ['id' => 'user-103', 'name' => 'Old Driver']],
        'sync_status' => 'local_modified',
    ]);

    $this->postJson('/api/fleet/drivers/manual/'.$driver->id.'/push-geotab')->assertOk();
    $job = GeotabWriteJob::query()->firstOrFail();

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/approve')
        ->assertOk()
        ->assertJsonPath('data.status', 'failed')
        ->assertJsonPath('data.lastError', 'Device update failed.');

    expect(array_column($fake->set, 'typeName'))->toBe(['User', 'Device', 'User'])
        ->and(data_get($fake->set[2], 'entity.name'))->toBe('Old Driver')
        ->and($driver->refresh()->sync_status)->toBe('failed')
        ->and($vehicle->refresh()->sync_status)->toBe('failed');
});

test('driver create approval requires a temporary password and processes with it only at approval time', function () {
    app()->instance(GeotabService::class, new class extends GeotabService
    {
        public array $added = [];

        public function addEntity(string $typeName, array $entity): string
        {
            $this->added[] = compact('typeName', 'entity');

            return 'user-geotab-1';
        }
    });

    $this->postJson('/api/fleet/drivers/manual', [
        'name' => 'Approved Driver',
        'email' => 'approved.driver@example.test',
    ])->assertOk();

    $this->postJson('/api/fleet/drivers/manual/1/push-geotab')
        ->assertOk();

    $job = GeotabWriteJob::query()->firstOrFail();

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/approve')
        ->assertStatus(422);

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/approve', [
        'temporaryPassword' => 'Temporary123!',
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'succeeded')
        ->assertJsonPath('data.geotabId', 'user-geotab-1');

    $driver = ManualDriver::query()->firstOrFail();
    expect(data_get($driver->meta, 'syncStatus'))->toBe('synced')
        ->and(data_get($driver->meta, 'geotabUserId'))->toBe('user-geotab-1');
});

test('legacy direct geotab route endpoints are gone and do not stage jobs', function () {
    $this->postJson('/api/fleet/geotab/routes', [
        'name' => 'Warehouse to Customer',
        'deviceGeotabId' => 'device-1',
        'stops' => [
            ['zoneId' => 'zone-a', 'scheduledAt' => '2026-05-05T09:00:00Z'],
            ['zoneId' => 'zone-b', 'expectedStopDurationMinutes' => 15],
        ],
    ])
        ->assertGone()
        ->assertJsonPath('success', false)
        ->assertJsonPath('message', 'This direct GeoTab route write-back endpoint is deprecated. Save the route locally, review the Push to GeoTab preview, then confirm staging through /api/fleet/routes/{routeId}/push-geotab.');

    $this->postJson('/api/fleet/geotab/routes/route-1/assign-device', [
        'deviceGeotabId' => 'device-2',
    ])
        ->assertGone()
        ->assertJsonPath('success', false)
        ->assertJsonPath('message', 'This direct GeoTab route assignment endpoint is deprecated. Update the local route assignment, review the Push to GeoTab preview, then confirm staging through /api/fleet/routes/{routeId}/push-geotab.');

    expect(GeotabWriteJob::query()->count())->toBe(0);
});

test('fleet route crud stores ordered stops and stages geotab approval when assignable', function () {
    $response = $this->postJson('/api/fleet/routes', [
        'name' => 'North Laguna Template',
        'description' => 'Reusable route template for northern deliveries.',
        'assignedVehicleGeotabId' => 'device-route-1',
        'assignedVehiclePlate' => 'PTC-401',
        'stops' => [
            [
                'name' => 'Warehouse',
                'zoneId' => 'zone-start',
                'latitude' => 14.2788,
                'longitude' => 121.1248,
                'estimatedStopDurationMinutes' => 10,
            ],
            [
                'name' => 'Client Dock',
                'zoneId' => 'zone-end',
                'latitude' => 14.3001,
                'longitude' => 121.1402,
                'estimatedStopDurationMinutes' => 20,
            ],
        ],
    ])
        ->assertOk()
        ->assertJsonPath('data.name', 'North Laguna Template')
        ->assertJsonPath('data.stopCount', 2)
        ->assertJsonPath('data.assignedVehicle', 'PTC-401')
        ->assertJsonPath('data.syncStatus', 'local_modified')
        ->assertJsonPath('data.stops.0.sequence', 1)
        ->assertJsonPath('data.stops.1.name', 'Client Dock');

    $routeId = $response->json('data.localId');
    expect(FleetRoute::query()->count())->toBe(1)
        ->and(GeotabWriteJob::query()->where('local_type', 'fleet_route')->where('action', 'route.create')->count())->toBe(0);

    $this->postJson('/api/fleet/routes/local-route-'.$routeId.'/push-geotab', ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewOnly', true);

    expect(GeotabWriteJob::query()->where('local_type', 'fleet_route')->where('action', 'route.create')->count())->toBe(0);

    $this->postJson('/api/fleet/routes/local-route-'.$routeId.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    expect(GeotabWriteJob::query()->where('local_type', 'grouped_writeback')->where('action', 'group.route_device_assignment')->count())->toBe(1);

    $this->patchJson('/api/fleet/routes/local-route-'.$routeId, [
        'name' => 'North Laguna Edited',
        'description' => 'Updated route template.',
        'assignedVehicleGeotabId' => 'device-route-2',
        'assignedVehiclePlate' => 'PTC-402',
        'stops' => [
            [
                'name' => 'Client Dock',
                'zoneId' => 'zone-end',
                'latitude' => 14.3001,
                'longitude' => 121.1402,
                'estimatedStopDurationMinutes' => 20,
            ],
            [
                'name' => 'Warehouse',
                'zoneId' => 'zone-start',
                'latitude' => 14.2788,
                'longitude' => 121.1248,
                'estimatedStopDurationMinutes' => 10,
            ],
        ],
    ])
        ->assertOk()
        ->assertJsonPath('data.name', 'North Laguna Edited')
        ->assertJsonPath('data.stops.0.name', 'Client Dock')
        ->assertJsonPath('data.stops.1.sequence', 2)
        ->assertJsonPath('data.syncStatus', 'local_modified');

    $this->postJson('/api/fleet/routes/local-route-'.$routeId.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    expect(GeotabWriteJob::query()->where('local_type', 'grouped_writeback')->where('action', 'group.route_device_assignment')->count())->toBeGreaterThanOrEqual(2);
});

test('fleet route push groups route creation and device assignment with shared preview', function () {
    $response = $this->postJson('/api/fleet/routes', [
        'name' => 'Grouped Route Assignment',
        'assignedVehicleGeotabId' => 'device-route-group',
        'assignedVehiclePlate' => 'PTC-701',
        'stops' => [
            [
                'name' => 'Warehouse',
                'zoneId' => 'zone-start',
                'latitude' => 14.2788,
                'longitude' => 121.1248,
            ],
            [
                'name' => 'Client',
                'zoneId' => 'zone-client',
                'latitude' => 14.2888,
                'longitude' => 121.1348,
            ],
        ],
    ])->assertOk();

    $routeId = $response->json('data.id');

    $this->postJson('/api/fleet/routes/'.$routeId.'/push-geotab', ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewPayload.isGrouped', true)
        ->assertJsonPath('data.previewPayload.groups.0.entityType', 'Route')
        ->assertJsonPath('data.previewPayload.groups.1.entityType', 'Route Device Assignment');

    $this->postJson('/api/fleet/routes/'.$routeId.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    $job = GeotabWriteJob::query()->firstOrFail();
    expect($job->action)->toBe('group.route_device_assignment')
        ->and($job->local_type)->toBe('grouped_writeback')
        ->and(data_get($job->preview_payload, 'isGrouped'))->toBeTrue()
        ->and(data_get($job->payload, 'operations'))->toHaveCount(2)
        ->and(data_get($job->payload, 'operations.0.action'))->toBe('route.create')
        ->and(data_get($job->payload, 'operations.1.action'))->toBe('route.assign_device');
});

test('fleet route push auto stages geotab zones for coordinate only stops', function () {
    SystemSetting::query()->create([
        'geotab_default_group_id' => 'GroupPioneerCompanyId',
    ]);

    $fake = new class extends GeotabService
    {
        public array $added = [];

        public array $set = [];

        public function addEntity(string $typeName, array $entity): string
        {
            $this->added[] = compact('typeName', 'entity');

            return match ($typeName) {
                'Zone' => 'zone-created-'.count(array_filter($this->added, fn ($item) => $item['typeName'] === 'Zone')),
                'Route' => 'route-created-auto-zone',
                default => 'rpi-'.count($this->added),
            };
        }

        public function setEntity(string $typeName, array $entity): void
        {
            $this->set[] = compact('typeName', 'entity');
        }
    };
    app()->instance(GeotabService::class, $fake);

    $response = $this->postJson('/api/fleet/routes', [
        'name' => 'Coordinate Only Push',
        'comment' => 'Deliver through Gate 2 after stock release.',
        'routeType' => 'planned',
        'scheduledStartAt' => now()->addDay()->toIso8601String(),
        'assignedVehicleGeotabId' => 'device-coordinate-route',
        'assignedVehiclePlate' => 'PTC-801',
        'stops' => [
            ['name' => 'Warehouse Gate', 'latitude' => 14.2788, 'longitude' => 121.1248],
            ['name' => 'Customer Dock', 'latitude' => 14.3001, 'longitude' => 121.1402],
        ],
    ])->assertOk()
        ->assertJsonPath('data.routeType', 'planned')
        ->assertJsonPath('data.comment', 'Deliver through Gate 2 after stock release.');

    $routeId = $response->json('data.id');

    $this->postJson('/api/fleet/routes/'.$routeId.'/push-geotab', ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewPayload.isGrouped', true)
        ->assertJsonPath('data.previewPayload.groups.0.entityType', 'Route Stop Zone')
        ->assertJsonPath('data.previewPayload.groups.2.entityType', 'Route')
        ->assertJsonPath('data.previewPayload.groups.3.entityType', 'Route Device Assignment');

    $this->postJson('/api/fleet/routes/'.$routeId.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    $job = GeotabWriteJob::query()->firstOrFail();
    expect(data_get($job->payload, 'operations'))->toHaveCount(4)
        ->and(data_get($job->payload, 'operations.0.action'))->toBe('zone.create')
        ->and(data_get($job->payload, 'operations.0.payload.zone.groups.0.id'))->toBe('GroupPioneerCompanyId')
        ->and(data_get($job->payload, 'operations.1.action'))->toBe('zone.create')
        ->and(data_get($job->payload, 'operations.1.payload.zone.groups.0.id'))->toBe('GroupPioneerCompanyId')
        ->and(data_get($job->payload, 'operations.2.action'))->toBe('route.create')
        ->and(data_get($job->payload, 'operations.2.payload.route.comment'))->toBe('Deliver through Gate 2 after stock release.')
        ->and(data_get($job->payload, 'operations.3.action'))->toBe('route.assign_device');

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/approve')
        ->assertOk()
        ->assertJsonPath('data.status', 'succeeded');

    expect(array_column($fake->added, 'typeName'))->toBe(['Zone', 'Zone', 'Route', 'RoutePlanItem', 'RoutePlanItem'])
        ->and(array_column($fake->set, 'typeName'))->toBe(['Route'])
        ->and(data_get($fake->added[2], 'entity.name'))->toBe('Coordinate Only Push')
        ->and(data_get($fake->added[3], 'entity.zone.id'))->toBe('zone-created-1')
        ->and(data_get($fake->added[4], 'entity.zone.id'))->toBe('zone-created-2');

    $route = FleetRoute::query()->with('stops')->firstOrFail();
    expect($route->sync_status)->toBe('synced')
        ->and($route->geotab_route_id)->toBe('route-created-auto-zone')
        ->and(data_get($route->geotab_snapshot, 'route.device.id'))->toBe('device-coordinate-route')
        ->and(data_get($route->geotab_snapshot, 'planItems.0.zone.id'))->toBe('zone-created-1')
        ->and($route->stops->pluck('geotab_zone_id')->all())->toBe(['zone-created-1', 'zone-created-2']);
});

test('grouped route device assignment processes route then assignment and syncs route', function () {
    $fake = new class extends GeotabService
    {
        public array $added = [];

        public array $set = [];

        public function addEntity(string $typeName, array $entity): string
        {
            $this->added[] = compact('typeName', 'entity');

            return $typeName === 'Route' ? 'route-created-701' : 'rpi-'.count($this->added);
        }

        public function setEntity(string $typeName, array $entity): void
        {
            $this->set[] = compact('typeName', 'entity');
        }
    };
    app()->instance(GeotabService::class, $fake);

    $response = $this->postJson('/api/fleet/routes', [
        'name' => 'Process Grouped Route',
        'assignedVehicleGeotabId' => 'device-route-process',
        'assignedVehiclePlate' => 'PTC-702',
        'stops' => [
            ['name' => 'A', 'zoneId' => 'zone-a', 'latitude' => 14.1, 'longitude' => 121.1],
            ['name' => 'B', 'zoneId' => 'zone-b', 'latitude' => 14.2, 'longitude' => 121.2],
        ],
    ])->assertOk();

    $this->postJson('/api/fleet/routes/'.$response->json('data.id').'/push-geotab')->assertOk();
    $job = GeotabWriteJob::query()->firstOrFail();

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/approve')
        ->assertOk()
        ->assertJsonPath('data.status', 'succeeded')
        ->assertJsonPath('data.result.typeName', 'GroupedWriteBack');

    expect(array_column($fake->added, 'typeName'))->toBe(['Route', 'RoutePlanItem', 'RoutePlanItem'])
        ->and(array_column($fake->set, 'typeName'))->toBe(['Route'])
        ->and(data_get($fake->set[0], 'entity.id'))->toBe('route-created-701')
        ->and(data_get($fake->set[0], 'entity.device.id'))->toBe('device-route-process');

    $route = FleetRoute::query()->firstOrFail();
    expect($route->sync_status)->toBe('synced')
        ->and($route->pending_write_job_id)->toBeNull()
        ->and($route->geotab_route_id)->toBe('route-created-701')
        ->and(data_get($route->geotab_snapshot, 'route.device.id'))->toBe('device-route-process');
});

test('fleet route delete soft deletes and stages geotab removal when synced', function () {
    $route = FleetRoute::query()->create([
        'name' => 'Synced Route',
        'assigned_vehicle_geotab_id' => 'device-route',
        'assigned_vehicle_plate' => 'PTC-900',
        'geotab_route_id' => 'route-geotab-900',
        'sync_status' => 'synced',
    ]);
    $route->stops()->createMany([
        ['stop_sequence' => 1, 'stop_name' => 'A', 'latitude' => 14.1, 'longitude' => 121.1],
        ['stop_sequence' => 2, 'stop_name' => 'B', 'latitude' => 14.2, 'longitude' => 121.2],
    ]);

    $this->deleteJson('/api/fleet/routes/local-route-'.$route->id)
        ->assertOk()
        ->assertJsonPath('data.status', 'deleted')
        ->assertJsonPath('data.syncStatus', 'local_modified');

    expect(GeotabWriteJob::query()->where('action', 'route.remove')->where('local_id', (string) $route->id)->count())->toBe(0);

    $this->postJson('/api/fleet/routes/local-route-'.$route->id.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    $route->refresh();
    expect($route->status)->toBe('deleted')
        ->and($route->deleted_at)->not->toBeNull()
        ->and(GeotabWriteJob::query()->where('action', 'route.remove')->where('local_id', (string) $route->id)->count())->toBe(1);
});

test('manual vehicle crud stages geotab device writeback and protects active vehicles', function () {
    $registrationDate = now()->addDays(45)->toDateString();
    $response = $this->postJson('/api/fleet/vehicles/manual', [
        'plateNumber' => 'PTC-777',
        'vehicleType' => 'Drop-side Truck',
        'makeModel' => 'Isuzu F-Series',
        'year' => 2024,
        'chassisNumber' => 'CHS-777',
        'vin' => 'VIN-777',
        'fuelType' => 'Diesel',
        'fuelCapacityLiters' => 180,
        'cargoCapacityKg' => 4500,
        'geotabDeviceId' => 'device-vehicle-777',
        'registrationExpiryDate' => $registrationDate,
        'insuranceExpiryDate' => now()->addDays(90)->toDateString(),
        'status' => 'Active',
    ])
        ->assertOk()
        ->assertJsonPath('data.plate', 'PTC-777')
        ->assertJsonPath('data.vehicleType', 'Drop-side Truck')
        ->assertJsonPath('data.fuelType', 'Diesel')
        ->assertJsonPath('data.cargoCapacityKg', 4500)
        ->assertJsonPath('data.syncStatus', 'local_modified');

    $vehicleId = $response->json('data.localId');
    expect(ManualVehicle::query()->count())->toBe(1)
        ->and(GeotabWriteJob::query()
            ->where('local_type', 'manual_vehicle')
            ->where('action', 'vehicle.update_device')
            ->count())->toBe(0);

    $this->postJson('/api/fleet/vehicles/manual/'.$vehicleId.'/push-geotab', ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewOnly', true);

    expect(GeotabWriteJob::query()->where('local_type', 'manual_vehicle')->where('action', 'vehicle.update_device')->count())->toBe(0);

    $this->postJson('/api/fleet/vehicles/manual/'.$vehicleId.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    $this->patchJson('/api/fleet/vehicles/manual/'.$vehicleId, [
        'vehicleType' => 'Refrigerated Truck',
        'fuelType' => 'Diesel',
        'cargoCapacityKg' => 5000,
        'registrationExpiryDate' => now()->addDays(30)->toDateString(),
    ])
        ->assertOk()
        ->assertJsonPath('data.vehicleType', 'Refrigerated Truck')
        ->assertJsonPath('data.cargoCapacityKg', 5000);

    $this->deleteJson('/api/fleet/vehicles/manual/'.$vehicleId, [
        'reason' => 'Reserve unit only.',
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'inactive');
});

test('fleet client crud returns account metrics and audits key changes', function () {
    $clientResponse = $this->postJson('/api/fleet/clients', [
        'companyName' => 'Empire Parts',
        'contactPersonName' => 'Ana Reyes',
        'contactNumber' => '09171234567',
        'email' => 'ana@example.test',
        'billingAddress' => 'Cabuyao, Laguna',
        'deliveryAddress' => 'Warehouse Gate 2',
        'clientType' => 'Priority',
        'paymentTerms' => '30 days net',
        'freeDeliveryThreshold' => 85000,
        'erpCustomerId' => 'ERP-EMP-001',
        'status' => 'Active',
    ])
        ->assertOk()
        ->assertJsonPath('data.companyName', 'Empire Parts')
        ->assertJsonPath('data.clientType', 'priority')
        ->assertJsonPath('data.paymentTerms', '30_days_net')
        ->assertJsonPath('data.freeDeliveryThreshold', 85000);

    $clientId = $clientResponse->json('data.localId');

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-CLIENT-CRUD',
        'customer' => 'Empire Parts',
        'origin' => 'Cabuyao Warehouse',
        'destination' => 'Makati Client',
        'cargoType' => 'General',
        'totalWeightKg' => 1200,
        'orderValue' => 90000,
        'amount' => 2500,
        'vehicle' => 'PTC-001',
        'driver' => 'Driver One',
        'scheduledDepartureAt' => now()->toIso8601String(),
        'status' => 'completed',
    ])->assertOk()
        ->assertJsonPath('data.freeDeliveryCandidate', true)
        ->assertJsonPath('data.freeDeliveryThreshold', 85000);

    $this->patchJson('/api/fleet/clients/'.$clientId, [
        'companyName' => 'Empire Parts Trading',
        'billingAddress' => 'Cabuyao Laguna Main Office',
        'contactPersonName' => 'Ana Reyes',
        'contactNumber' => '09171234567',
    ])
        ->assertOk()
        ->assertJsonPath('data.companyName', 'Empire Parts Trading')
        ->assertJsonCount(2, 'data.auditTrail');

    $client = FleetClient::query()->find($clientId);
    expect($client)->not->toBeNull()
        ->and($client->audit_trail)->toHaveCount(2);

    $this->deleteJson('/api/fleet/clients/'.$clientId, [
        'reason' => 'Account inactive.',
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'inactive')
        ->assertJsonPath('data.isActive', false);
});

test('fleet zone crud stores polygon boundaries and stages geotab approval', function () {
    $client = FleetClient::query()->create([
        'company_name' => 'Zone Client',
        'contact_person_name' => 'Juan Zone',
        'contact_number' => '09170000000',
        'billing_address' => 'Cabuyao',
    ]);

    $payload = [
        'name' => 'Zone Customer Site',
        'zoneType' => 'Customer Site',
        'clientId' => (string) $client->id,
        'boundaryPoints' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
    ];

    $response = $this->postJson('/api/fleet/zones', $payload)
        ->assertOk()
        ->assertJsonPath('data.name', 'Zone Customer Site')
        ->assertJsonPath('data.zoneType', 'Customer Site')
        ->assertJsonPath('data.clientName', 'Zone Client')
        ->assertJsonPath('data.syncStatus', 'not_staged')
        ->json('data');

    expect($response['points'])->toHaveCount(3)
        ->and(GeotabWriteJob::query()->where('local_type', 'fleet_zone')->where('action', 'zone.create')->count())->toBe(0);

    $this->postJson('/api/fleet/zones/'.$response['id'].'/push-geotab', ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewOnly', true);

    expect(GeotabWriteJob::query()->where('local_type', 'fleet_zone')->where('action', 'zone.create')->count())->toBe(0);

    $this->postJson('/api/fleet/zones/'.$response['id'].'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    expect(GeotabWriteJob::query()->where('local_type', 'fleet_zone')->where('action', 'zone.create')->count())->toBe(1);

    $this->patchJson('/api/fleet/zones/'.$response['id'], [
        'name' => 'Updated Zone Customer Site',
        'zoneType' => 'Depot',
        'boundaryPoints' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2808, 'longitude' => 121.1248],
            ['latitude' => 14.2808, 'longitude' => 121.1268],
            ['latitude' => 14.2788, 'longitude' => 121.1268],
        ],
    ])
        ->assertOk()
        ->assertJsonPath('data.name', 'Updated Zone Customer Site')
        ->assertJsonPath('data.zoneType', 'Depot')
        ->assertJsonPath('data.syncStatus', 'not_staged');

    $this->postJson('/api/fleet/zones/'.$response['id'].'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    expect(GeotabWriteJob::query()->where('local_type', 'fleet_zone')->where('action', 'zone.create')->count())->toBeGreaterThanOrEqual(2);
});

test('fleet zones list does not repeat local rows already present in the cached snapshot', function () {
    $zone = FleetZone::query()->create([
        'name' => 'Single Managed Depot',
        'zone_type' => 'Depot',
        'boundary_points' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
        'status' => 'active',
        'sync_status' => 'not_staged',
    ]);

    Cache::put('geotab_fleet_snapshot_v4_fresh', [
        'zones' => [[
            'id' => 'local-zone-'.$zone->id,
            'zoneId' => 'local-zone-'.$zone->id,
            'name' => 'Single Managed Depot',
            'source' => 'pioneer_zone',
            'managedLocally' => true,
            'points' => $zone->boundary_points,
        ]],
    ]);

    $this->getJson('/api/fleet/zones')
        ->assertOk()
        ->assertJsonCount(1, 'data')
        ->assertJsonPath('data.0.name', 'Single Managed Depot')
        ->assertJsonPath('data.0.managedLocally', true);
});

test('fleet zone create rejects the same active named polygon regardless of vertex start position', function () {
    $payload = [
        'name' => 'Duplicate Protected Site',
        'zoneType' => 'Customer Site',
        'boundaryPoints' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
    ];

    $this->postJson('/api/fleet/zones', $payload)->assertOk();

    $this->postJson('/api/fleet/zones', [
        ...$payload,
        'boundaryPoints' => [
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
            ['latitude' => 14.2788, 'longitude' => 121.1248],
        ],
    ])
        ->assertStatus(409)
        ->assertJsonPath('message', 'A zone with the same name and boundary already exists.');

    expect(FleetZone::query()->where('name', 'Duplicate Protected Site')->count())->toBe(1);
});

test('fleet zone push embeds the configured GeoTab company group', function () {
    SystemSetting::query()->create([
        'geotab_default_group_id' => 'GroupPioneerCompanyId',
    ]);
    $zone = FleetZone::query()->create([
        'name' => 'Configured Group Site',
        'zone_type' => 'Customer Site',
        'boundary_points' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
        'center_latitude' => 14.2794,
        'center_longitude' => 121.1252,
        'status' => 'active',
        'sync_status' => 'not_staged',
    ]);

    $this->postJson('/api/fleet/zones/local-zone-'.$zone->id.'/push-geotab')
        ->assertOk();

    $job = GeotabWriteJob::query()->firstOrFail();
    expect(data_get($job->payload, 'zone.groups.0.id'))->toBe('GroupPioneerCompanyId');

    $this->getJson('/api/fleet/geotab/writeback/jobs')
        ->assertOk()
        ->assertJsonPath('data.0.requiresGeotabCompanyGroup', true)
        ->assertJsonPath('data.0.geotabCompanyGroupConfigured', true);
});

test('approved fleet zone writeback calls geotab add and stores returned zone id', function () {
    SystemSetting::query()->create([
        'geotab_default_group_id' => 'GroupPioneerCompanyId',
    ]);

    $fake = new class extends GeotabService
    {
        public array $added = [];

        public function addEntity(string $typeName, array $entity): string
        {
            $this->added[] = compact('typeName', 'entity');

            return 'zone-created-from-approval';
        }
    };
    app()->instance(GeotabService::class, $fake);

    $zone = FleetZone::query()->create([
        'name' => 'Approval Push Site',
        'zone_type' => 'Customer Site',
        'boundary_points' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
        'center_latitude' => 14.2794,
        'center_longitude' => 121.1252,
        'status' => 'active',
        'sync_status' => 'not_staged',
    ]);

    $this->postJson('/api/fleet/zones/local-zone-'.$zone->id.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    $job = GeotabWriteJob::query()->firstOrFail();

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/approve')
        ->assertOk()
        ->assertJsonPath('data.status', 'succeeded')
        ->assertJsonPath('data.geotabId', 'zone-created-from-approval');

    expect(array_column($fake->added, 'typeName'))->toBe(['Zone'])
        ->and(data_get($fake->added[0], 'entity.groups.0.id'))->toBe('GroupPioneerCompanyId')
        ->and($zone->refresh()->geotab_zone_id)->toBe('zone-created-from-approval')
        ->and($zone->sync_status)->toBe('synced')
        ->and(data_get($zone->geotab_snapshot, 'zone.id'))->toBe('zone-created-from-approval')
        ->and(data_get($zone->geotab_snapshot, 'zone.groups.0.id'))->toBe('GroupPioneerCompanyId');
});

test('approved fleet zone writeback fails clearly when company group is missing', function () {
    app()->instance(GeotabService::class, new class extends GeotabService
    {
        public function addEntity(string $typeName, array $entity): string
        {
            throw new RuntimeException('GeoTab should not be called without a company group.');
        }
    });

    $zone = FleetZone::query()->create([
        'name' => 'Missing Group Site',
        'zone_type' => 'Customer Site',
        'boundary_points' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
        'center_latitude' => 14.2794,
        'center_longitude' => 121.1252,
        'status' => 'active',
        'sync_status' => 'not_staged',
    ]);

    $this->postJson('/api/fleet/zones/local-zone-'.$zone->id.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    $job = GeotabWriteJob::query()->firstOrFail();

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/approve')
        ->assertOk()
        ->assertJsonPath('data.status', 'failed')
        ->assertJsonPath('data.lastError', 'Zone push requires GeoTab Company Group ID to be configured in Settings -> Map Settings before zones can be pushed.');

    $this->getJson('/api/fleet/geotab/writeback/jobs')
        ->assertOk()
        ->assertJsonPath('data.0.requiresGeotabCompanyGroup', true)
        ->assertJsonPath('data.0.geotabCompanyGroupConfigured', false)
        ->assertJsonPath('data.0.lastError', 'Zone push requires GeoTab Company Group ID to be configured in Settings -> Map Settings before zones can be pushed.');

    expect($zone->refresh()->sync_status)->toBe('failed')
        ->and($zone->sync_error)->toBe('Zone push requires GeoTab Company Group ID to be configured in Settings -> Map Settings before zones can be pushed.');
});

test('fleet zone push groups zone and client device assignment when client has assigned device', function () {
    $client = FleetClient::query()->create([
        'company_name' => 'Grouped Zone Client',
        'contact_person_name' => 'Client Contact',
        'contact_number' => '09170000000',
        'billing_address' => 'Cabuyao',
    ]);
    ClientVehicleAssignment::query()->create([
        'client_name' => 'Grouped Zone Client',
        'vehicle_geotab_id' => 'device-zone-group',
        'vehicle_plate' => 'PTC-801',
        'status' => 'active',
    ]);
    $vehicle = ManualVehicle::query()->create([
        'plate_number' => 'PTC-801',
        'vehicle_type' => 'Drop-side Truck',
        'fuel_type' => 'Diesel',
        'cargo_capacity_kg' => 3000,
        'geotab_device_id' => 'device-zone-group',
        'registration_expiry_date' => now()->addYear()->toDateString(),
        'geotab_snapshot' => ['entity' => ['id' => 'device-zone-group', 'name' => 'PTC-801']],
        'sync_status' => 'synced',
    ]);

    $response = $this->postJson('/api/fleet/zones', [
        'name' => 'Grouped Client Site',
        'zoneType' => 'Customer Site',
        'clientId' => (string) $client->id,
        'boundaryPoints' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
    ])->assertOk();

    $this->postJson('/api/fleet/zones/'.$response->json('data.id').'/push-geotab', ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewPayload.isGrouped', true)
        ->assertJsonPath('data.previewPayload.groups.0.entityType', 'Zone')
        ->assertJsonPath('data.previewPayload.groups.1.entityType', 'Device Client-Zone Assignment');

    $this->postJson('/api/fleet/zones/'.$response->json('data.id').'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    $job = GeotabWriteJob::query()->firstOrFail();
    expect($job->action)->toBe('group.zone_device_assignment')
        ->and(data_get($job->payload, 'operations'))->toHaveCount(2)
        ->and(data_get($job->payload, 'operations.0.action'))->toBe('zone.create')
        ->and(data_get($job->payload, 'operations.1.action'))->toBe('vehicle.update_device')
        ->and($vehicle->refresh()->pending_write_job_id)->toBe($job->id);
});

test('grouped zone device assignment rolls back created zone when device update fails', function () {
    SystemSetting::query()->create([
        'geotab_default_group_id' => 'GroupPioneerCompanyId',
    ]);

    $fake = new class extends GeotabService
    {
        public array $added = [];

        public array $set = [];

        public array $removed = [];

        public function addEntity(string $typeName, array $entity): string
        {
            $this->added[] = compact('typeName', 'entity');

            return 'zone-created-801';
        }

        public function setEntity(string $typeName, array $entity): void
        {
            $this->set[] = compact('typeName', 'entity');
            if ($typeName === 'Device') {
                throw new RuntimeException('Device client-zone assignment failed.');
            }
        }

        public function removeEntity(string $typeName, array $entity): void
        {
            $this->removed[] = compact('typeName', 'entity');
        }
    };
    app()->instance(GeotabService::class, $fake);

    $client = FleetClient::query()->create([
        'company_name' => 'Rollback Zone Client',
        'contact_person_name' => 'Client Contact',
        'contact_number' => '09170000000',
        'billing_address' => 'Cabuyao',
    ]);
    ClientVehicleAssignment::query()->create([
        'client_name' => 'Rollback Zone Client',
        'vehicle_geotab_id' => 'device-zone-rollback',
        'vehicle_plate' => 'PTC-802',
        'status' => 'active',
    ]);
    $vehicle = ManualVehicle::query()->create([
        'plate_number' => 'PTC-802',
        'vehicle_type' => 'Drop-side Truck',
        'fuel_type' => 'Diesel',
        'cargo_capacity_kg' => 3000,
        'geotab_device_id' => 'device-zone-rollback',
        'registration_expiry_date' => now()->addYear()->toDateString(),
        'geotab_snapshot' => ['entity' => ['id' => 'device-zone-rollback', 'name' => 'PTC-802']],
        'sync_status' => 'synced',
    ]);

    $response = $this->postJson('/api/fleet/zones', [
        'name' => 'Rollback Client Site',
        'zoneType' => 'Customer Site',
        'clientId' => (string) $client->id,
        'boundaryPoints' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
    ])->assertOk();

    $this->postJson('/api/fleet/zones/'.$response->json('data.id').'/push-geotab')->assertOk();
    $job = GeotabWriteJob::query()->firstOrFail();

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/approve')
        ->assertOk()
        ->assertJsonPath('data.status', 'failed')
        ->assertJsonPath('data.lastError', 'Device client-zone assignment failed.');

    expect(array_column($fake->added, 'typeName'))->toBe(['Zone'])
        ->and(array_column($fake->set, 'typeName'))->toBe(['Device'])
        ->and(array_column($fake->removed, 'typeName'))->toBe(['Zone'])
        ->and(data_get($fake->removed[0], 'entity.id'))->toBe('zone-created-801')
        ->and(FleetZone::query()->firstOrFail()->sync_status)->toBe('failed')
        ->and($vehicle->refresh()->sync_status)->toBe('failed');
});

test('fleet zone deletion previews and stages geotab removal when synced', function () {
    $zone = FleetZone::query()->create([
        'name' => 'Synced Zone',
        'zone_type' => 'Depot',
        'boundary_points' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
        'center_latitude' => 14.2794,
        'center_longitude' => 121.1252,
        'geotab_zone_id' => 'zone-synced-1',
        'sync_status' => 'synced',
    ]);

    $this->deleteJson('/api/fleet/zones/local-zone-'.$zone->id)
        ->assertStatus(409);

    $this->deleteJson('/api/fleet/zones/local-zone-'.$zone->id, ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewOnly', true)
        ->assertJsonPath('data.geotabZoneId', 'zone-synced-1')
        ->assertJsonPath('data.previewPayload.entityType', 'Zone Removal');

    expect(GeotabWriteJob::query()
        ->where('local_type', 'fleet_zone')
        ->where('local_id', (string) $zone->id)
        ->where('action', 'zone.remove')
        ->exists())->toBeFalse();

    $this->deleteJson('/api/fleet/zones/local-zone-'.$zone->id, ['confirmedPreview' => true])
        ->assertOk()
        ->assertJsonPath('data.status', 'deleted')
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    expect(FleetZone::query()->find($zone->id)?->status)->toBe('deleted')
        ->and(GeotabWriteJob::query()
            ->where('local_type', 'fleet_zone')
            ->where('local_id', (string) $zone->id)
            ->where('action', 'zone.remove')
            ->exists())->toBeTrue();
});

test('fleet local-only zone deletion permanently removes record without geotab job', function () {
    $zone = FleetZone::query()->create([
        'name' => 'Local Draft Zone',
        'zone_type' => 'Customer Site',
        'boundary_points' => [
            ['latitude' => 14.2788, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1248],
            ['latitude' => 14.2798, 'longitude' => 121.1258],
        ],
        'status' => 'active',
        'sync_status' => 'not_staged',
    ]);

    $this->deleteJson('/api/fleet/zones/local-zone-'.$zone->id)
        ->assertOk()
        ->assertJsonPath('data.hardDeleted', true);

    expect(FleetZone::query()->find($zone->id))->toBeNull()
        ->and(GeotabWriteJob::query()->where('local_type', 'fleet_zone')->exists())->toBeFalse();
});

test('pioneer operating zones seed as local mock boundaries only', function () {
    $this->seed(PioneerOperatingZonesSeeder::class);

    expect(FleetZone::query()->count())->toBe(6)
        ->and(FleetZone::query()->where('name', 'Pioneer Cabuyao Depot')->value('zone_type'))->toBe('Depot')
        ->and(FleetZone::query()->where('name', 'Araneta Center Delivery Zone')->exists())->toBeTrue()
        ->and(FleetZone::query()->where('name', 'Camp Crame Delivery Zone')->exists())->toBeTrue()
        ->and(FleetZone::query()->where('name', 'Isuzu Philippines Zone')->exists())->toBeTrue()
        ->and(FleetZone::query()->where('name', 'Davao Distribution Zone')->exists())->toBeTrue()
        ->and(FleetZone::query()->where('name', 'Empire Oil Service Zone')->exists())->toBeTrue()
        ->and(FleetZone::query()->whereNotNull('geotab_zone_id')->count())->toBe(0)
        ->and(data_get(FleetZone::query()->firstOrFail()->meta, 'isMockZone'))->toBeTrue();
});

test('geotab health includes writeback queue counts', function () {
    GeotabWriteJob::query()->create([
        'action' => 'route.create',
        'entity_type' => 'Route',
        'payload' => ['route' => ['name' => 'Queued Route']],
        'status' => 'pending_approval',
        'idempotency_key' => 'health-writeback',
    ]);

    $this->getJson('/api/fleet/geotab/health')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.writeBack.tableAvailable', true)
        ->assertJsonPath('data.writeBack.pendingApproval', 1)
        ->assertJsonPath('data.writeBack.totalPendingJobs', 1)
        ->assertJsonPath('data.writeBack.totalApprovedAwaitingExecution', 0)
        ->assertJsonPath('data.writeBack.totalFailedJobs', 0)
        ->assertJsonPath('data.write_back.pendingApproval', 1);
});

test('writeback failures retry with exponential backoff and become permanently failed', function () {
    app()->instance(GeotabService::class, new class extends GeotabService
    {
        public function addEntity(string $typeName, array $entity): string
        {
            throw new RuntimeException('GeoTab unavailable for write-back.');
        }
    });

    Carbon::setTestNow('2026-05-07 08:00:00');
    $job = GeotabWriteJob::query()->create([
        'action' => 'route.create',
        'entity_type' => 'Route',
        'payload' => ['route' => ['name' => 'Backoff Route']],
        'status' => 'approved',
        'attempts' => 0,
        'max_attempts' => 5,
        'approved_at' => now(),
        'idempotency_key' => 'backoff-writeback',
        'audit_trail' => [],
    ]);

    $service = app(GeotabWriteBackService::class);

    foreach ([1, 5, 30, 120] as $index => $minutes) {
        $service->processApproved(1);
        $job->refresh();
        expect($job->status)->toBe('failed')
            ->and($job->attempts)->toBe($index + 1)
            ->and($job->last_attempt_at?->toIso8601String())->not->toBeNull()
            ->and($job->next_attempt_at?->equalTo(now()->addMinutes($minutes)))->toBeTrue();

        Carbon::setTestNow($job->next_attempt_at?->copy()->addSecond());
    }

    $service->processApproved(1);
    $job->refresh();

    expect($job->status)->toBe('permanently_failed')
        ->and($job->attempts)->toBe(5)
        ->and($job->next_attempt_at)->toBeNull()
        ->and($job->permanently_failed_at)->not->toBeNull()
        ->and($job->audit_trail)->not->toBeEmpty();
});

test('writeback job audit trail is returned in approval center payload', function () {
    $routeResponse = $this->postJson('/api/fleet/routes', [
        'name' => 'Audited Route',
        'assignedVehicleGeotabId' => 'device-audit',
        'assignedVehiclePlate' => 'PTC-AUDIT',
        'stops' => [
            [
                'name' => 'Audit Start',
                'zoneId' => 'zone-a',
                'latitude' => 14.2,
                'longitude' => 121.1,
            ],
        ],
    ])->assertOk();

    $routeId = $routeResponse->json('data.id');
    $this->postJson('/api/fleet/routes/'.$routeId.'/push-geotab')->assertOk();

    $job = GeotabWriteJob::query()->firstOrFail();

    $this->postJson('/api/fleet/geotab/writeback/jobs/'.$job->id.'/approve', [
        'approvedBy' => 'ops-admin',
        'processNow' => false,
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'approved')
        ->assertJsonPath('data.auditTrail.0.event', 'created')
        ->assertJsonPath('data.auditTrail.1.event', 'approved')
        ->assertJsonPath('data.auditTrail.1.actor', 'ops-admin');
});

test('manual driver list exposes three geotab sync states from writeback jobs', function () {
    $notSynced = ManualDriver::query()->create(['name' => 'Not Synced Driver']);
    $pending = ManualDriver::query()->create(['name' => 'Pending Driver']);
    $synced = ManualDriver::query()->create(['name' => 'Synced Driver']);

    GeotabWriteJob::query()->create([
        'action' => 'driver.create',
        'entity_type' => 'User',
        'local_type' => 'manual_driver',
        'local_id' => (string) $pending->id,
        'payload' => ['entity' => ['name' => 'Pending Driver']],
        'status' => 'pending_approval',
        'idempotency_key' => 'pending-driver-sync',
    ]);
    GeotabWriteJob::query()->create([
        'action' => 'driver.create',
        'entity_type' => 'User',
        'local_type' => 'manual_driver',
        'local_id' => (string) $synced->id,
        'payload' => ['entity' => ['name' => 'Synced Driver']],
        'status' => 'succeeded',
        'geotab_id' => 'user-synced',
        'idempotency_key' => 'synced-driver-sync',
    ]);

    $drivers = $this->getJson('/api/fleet/drivers/manual')
        ->assertOk()
        ->json('data');

    $byName = collect($drivers)->keyBy('name');
    expect($byName['Not Synced Driver']['syncStatus'])->toBe('not_synced')
        ->and($byName['Pending Driver']['syncStatus'])->toBe('pending_approval')
        ->and($byName['Pending Driver']['syncLabel'])->toBe('GeoTab: Push awaiting approval')
        ->and($byName['Synced Driver']['syncStatus'])->toBe('synced')
        ->and($byName['Synced Driver']['geotabId'])->toBe('user-synced');
});
