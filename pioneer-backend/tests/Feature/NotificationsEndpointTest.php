<?php

use App\Models\NotificationHistory;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;

uses(RefreshDatabase::class);

beforeEach(function () {
    Cache::flush();
});

test('notifications endpoint returns meaningful empty real state', function () {
    Cache::put('geotab_fleet_snapshot_v4_fresh', ['notifications' => []], now()->addMinute());

    $this->getJson('/api/fleet/notifications')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonCount(0, 'data');
});

test('notifications endpoint returns stored history when snapshot has no rows', function () {
    Cache::put('geotab_fleet_snapshot_v4_fresh', ['notifications' => []], now()->addMinute());
    NotificationHistory::query()->create([
        'notification_id' => 'history-test-1',
        'title' => 'Stored Notice',
        'message' => 'This came from notification history.',
        'category' => 'system',
        'status' => 'sent',
        'audience' => 'internal',
        'payload' => ['url' => '/notifications'],
        'delivered_at' => now(),
    ]);

    $this->getJson('/api/fleet/notifications')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.0.id', 'history-test-1')
        ->assertJsonPath('data.0.title', 'Stored Notice')
        ->assertJsonPath('data.0.category', 'system')
        ->assertJsonPath('data.0.isRead', false);
});

test('notification read and delete state is applied to endpoint payload', function () {
    Cache::put('geotab_fleet_snapshot_v4_fresh', ['notifications' => []], now()->addMinute());
    NotificationHistory::query()->create([
        'notification_id' => 'history-test-2',
        'title' => 'Actionable Notice',
        'message' => 'Read and delete me.',
        'category' => 'alert',
        'status' => 'sent',
        'audience' => 'internal',
        'payload' => [],
        'delivered_at' => now(),
    ]);

    $this->postJson('/api/fleet/notifications/history-test-2/read')
        ->assertOk()
        ->assertJsonPath('data.isRead', true);

    $this->getJson('/api/fleet/notifications')
        ->assertOk()
        ->assertJsonPath('data.0.isRead', true);

    $this->deleteJson('/api/fleet/notifications/history-test-2')
        ->assertOk()
        ->assertJsonPath('data.deleted', true);

    $this->getJson('/api/fleet/notifications')
        ->assertOk()
        ->assertJsonCount(0, 'data');
});

test('stored unread notifications remain visible even when stale deleted cache state exists', function () {
    Cache::put('geotab_fleet_snapshot_v4_fresh', ['notifications' => []], now()->addMinute());

    foreach (range(1, 4) as $index) {
        NotificationHistory::query()->create([
            'notification_id' => 'unread-history-'.$index,
            'title' => 'Unread Notice '.$index,
            'message' => 'Unread database notification '.$index,
            'category' => $index === 1 ? 'alert' : 'system',
            'status' => 'sent',
            'audience' => 'internal',
            'payload' => ['url' => '/notifications'],
            'delivered_at' => now()->subMinutes($index),
        ]);
    }

    Cache::put('geotab_notification_state_v1', [
        'read' => [],
        'deleted' => [
            'unread-history-1' => now()->toIso8601String(),
            'unread-history-2' => now()->toIso8601String(),
            'unread-history-3' => now()->toIso8601String(),
            'unread-history-4' => now()->toIso8601String(),
        ],
    ], now()->addDays(14));

    $this->getJson('/api/fleet/notifications')
        ->assertOk()
        ->assertJsonCount(4, 'data')
        ->assertJsonPath('data.0.isRead', false)
        ->assertJsonPath('data.0.source', 'history');
});
