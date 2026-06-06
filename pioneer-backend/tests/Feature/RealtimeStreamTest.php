<?php

use App\Models\NotificationHistory;
use App\Services\GeotabFeedHarvester;
use App\Services\GeotabService;
use App\Services\RealtimeFleetEventBroadcaster;
use Carbon\CarbonInterface;
use Illuminate\Foundation\Testing\RefreshDatabase;

uses(RefreshDatabase::class);

test('notification history inserts publish realtime notification events', function () {
    $notification = NotificationHistory::query()->create([
        'notification_id' => 'realtime-notification-1',
        'title' => 'Dispatch Updated',
        'message' => 'A trip moved to in transit.',
        'category' => 'dispatch',
        'status' => 'sent',
        'audience' => 'internal',
        'payload' => ['url' => '/dispatch-queue', 'tag' => 'dispatch-updated'],
        'delivered_at' => now(),
    ]);

    $event = app(RealtimeFleetEventBroadcaster::class)->latestEvent('notification');

    expect($event)->not->toBeNull()
        ->and($event['event'])->toBe('notification')
        ->and(data_get($event, 'data.notification.id'))->toBe($notification->notification_id)
        ->and(data_get($event, 'data.notification.title'))->toBe('Dispatch Updated')
        ->and(data_get($event, 'data.unreadCount'))->toBe(1);
});

test('dispatch status changes create stored notifications and publish realtime payloads', function () {
    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-REAL-DISPATCH',
        'customer' => 'Realtime Client',
        'origin' => 'Pioneer Warehouse',
        'destination' => 'Client Warehouse',
        'amount' => 12500,
        'status' => 'pending',
    ])->assertOk();

    NotificationHistory::query()->delete();

    $this->patchJson('/api/fleet/trips/TRP-REAL-DISPATCH', [
        'status' => 'dispatched',
        'workflowPhaseNumber' => 10,
    ])
        ->assertOk()
        ->assertJsonPath('success', true);

    $notification = NotificationHistory::query()
        ->where('category', 'dispatch')
        ->where('title', 'Dispatch Status Changed')
        ->latest('id')
        ->first();

    $event = app(RealtimeFleetEventBroadcaster::class)->latestEvent('notification');

    expect($notification)->not->toBeNull()
        ->and($notification->message)->toContain('TRP-REAL-DISPATCH is now dispatched')
        ->and($notification->payload['url'])->toBe('/dispatch-queue')
        ->and($event)->not->toBeNull()
        ->and($event['event'])->toBe('notification')
        ->and(data_get($event, 'data.notification.id'))->toBe($notification->notification_id)
        ->and(data_get($event, 'data.notification.category'))->toBe('dispatch')
        ->and(data_get($event, 'data.notification.url'))->toBe('/dispatch-queue')
        ->and(data_get($event, 'data.unreadCount'))->toBe(1);

    $this->getJson('/api/fleet/notifications')
        ->assertOk()
        ->assertJsonFragment([
            'id' => $notification->notification_id,
            'title' => 'Dispatch Status Changed',
        ]);
});

test('device status feed rows publish realtime live vehicle events', function () {
    $geotab = new class extends GeotabService
    {
        public function getFeed(
            string $typeName,
            ?string $fromVersion = null,
            array $search = [],
            ?int $resultsLimit = null,
            ?CarbonInterface $fromDate = null,
            ?array $propertySelector = null,
        ): array {
            return [
                'toVersion' => 'device-status-version-1',
                'data' => [[
                    'id' => 'status-1',
                    'device' => ['id' => 'device-1', 'name' => 'NGO 7290'],
                    'dateTime' => '2026-05-06T08:00:00Z',
                    'latitude' => 14.5995,
                    'longitude' => 120.9842,
                    'speed' => 24,
                    'isDriving' => true,
                ]],
            ];
        }
    };

    (new GeotabFeedHarvester($geotab, app(RealtimeFleetEventBroadcaster::class)))
        ->sync('DeviceStatusInfo', 500);

    $event = app(RealtimeFleetEventBroadcaster::class)->latestEvent('live');

    expect($event)->not->toBeNull()
        ->and($event['event'])->toBe('live')
        ->and(data_get($event, 'data.vehicles.0.geotabId'))->toBe('device-1')
        ->and(data_get($event, 'data.vehicles.0.plate'))->toBe('NGO 7290')
        ->and(data_get($event, 'data.vehicles.0.latitude'))->toBe(14.5995)
        ->and(data_get($event, 'data.vehicles.0.isDriving'))->toBeTrue();
});

test('fleet stream emits cached realtime events in sse format', function () {
    app(RealtimeFleetEventBroadcaster::class)->publishLiveVehicles([[
        'geotabId' => 'device-2',
        'plate' => 'IAE 5512',
        'latitude' => 14.6,
        'longitude' => 121.0,
        'speed' => 0,
        'isDriving' => false,
    ]]);

    $response = $this->get('/api/fleet/stream?channels=live&once=1');
    $content = $response->streamedContent();

    expect($response->getStatusCode())->toBe(200)
        ->and($response->headers->get('Content-Type'))->toContain('text/event-stream')
        ->and($content)->toContain("event: live\n")
        ->and($content)->toContain('"geotabId":"device-2"');
});

test('geotab health reports sse mode and active client count', function () {
    app(RealtimeFleetEventBroadcaster::class)->registerSseClient('client-health-1', [
        'channels' => ['live', 'notification'],
        'connectedAt' => now()->toIso8601String(),
    ]);

    $response = $this->getJson('/api/fleet/geotab/health');

    $response->assertOk()
        ->assertJsonPath('data.sse.enabled', true)
        ->assertJsonPath('data.sse.transport', 'server_sent_events')
        ->assertJsonPath('data.sse.activeClients', 1)
        ->assertJsonPath('data.sse.active_clients', 1);

    app(RealtimeFleetEventBroadcaster::class)->unregisterSseClient('client-health-1');
});
