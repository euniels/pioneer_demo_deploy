<?php

namespace App\Services;

use App\Models\GeotabWriteJob;
use App\Models\NotificationHistory;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;

class RealtimeFleetEventBroadcaster
{
    private const LIVE_EVENT_KEY = 'pioneer_realtime_live_event_v1';

    private const NOTIFICATION_EVENT_KEY = 'pioneer_realtime_notification_event_v1';

    private const WRITEBACK_EVENT_KEY = 'pioneer_realtime_writeback_event_v1';

    private const LIVE_EVENT_LIST_KEY = 'pioneer_realtime_live_events_v1';

    private const NOTIFICATION_EVENT_LIST_KEY = 'pioneer_realtime_notification_events_v1';

    private const WRITEBACK_EVENT_LIST_KEY = 'pioneer_realtime_writeback_events_v1';

    private const SSE_CLIENTS_KEY = 'pioneer_realtime_sse_clients_v1';

    private const EVENT_TTL_SECONDS = 300;

    private const CLIENT_TTL_SECONDS = 360;

    private const MAX_RECENT_EVENTS = 50;

    public function registerSseClient(string $clientId, array $meta = []): void
    {
        $clients = $this->activeSseClientRows();
        $clients[$clientId] = [
            'clientId' => $clientId,
            'connectedAt' => $meta['connectedAt'] ?? now()->toIso8601String(),
            'lastSeenAt' => now()->toIso8601String(),
            'channels' => $meta['channels'] ?? [],
            'userKey' => $meta['userKey'] ?? null,
            'expiresAt' => now()->addSeconds(self::CLIENT_TTL_SECONDS)->toIso8601String(),
        ];

        Cache::put(self::SSE_CLIENTS_KEY, $clients, now()->addSeconds(self::CLIENT_TTL_SECONDS));
    }

    public function unregisterSseClient(string $clientId): void
    {
        $clients = $this->activeSseClientRows();
        unset($clients[$clientId]);

        Cache::put(self::SSE_CLIENTS_KEY, $clients, now()->addSeconds(self::CLIENT_TTL_SECONDS));
    }

    public function sseHealth(): array
    {
        $clients = $this->activeSseClientRows();

        return [
            'enabled' => (bool) config('pioneer.sse_enabled', true),
            'mode' => PHP_SAPI === 'cli-server' ? 'oneshot-dev-server' : 'stream',
            'transport' => 'server_sent_events',
            'phpSapi' => PHP_SAPI,
            'activeClients' => count($clients),
            'clients' => array_values($clients),
        ];
    }

    public function activeSseClientCountForUser(string $userKey): int
    {
        return collect($this->activeSseClientRows())
            ->filter(fn (array $client): bool => ($client['userKey'] ?? null) === $userKey)
            ->count();
    }

    public function publishLiveDeviceStatusRows(array $rows): ?array
    {
        $vehicles = [];
        foreach ($rows as $row) {
            if (! is_array($row)) {
                continue;
            }

            $vehicle = $this->vehicleFromDeviceStatusRow($row);
            if ($vehicle !== null) {
                $vehicles[] = $vehicle;
            }
        }

        if ($vehicles === []) {
            return null;
        }

        return $this->publishLiveVehicles($vehicles);
    }

    public function publishLiveVehicles(array $vehicles): array
    {
        $event = [
            'id' => $this->nextEventId('live'),
            'event' => 'live',
            'data' => [
                'vehicles' => array_values($vehicles),
                'lastSyncedAt' => now()->toIso8601String(),
                'servedFrom' => 'sse_feed',
            ],
        ];

        $this->storeEvent('live', $event);

        return $event;
    }

    public function publishNotification(NotificationHistory $notification): array
    {
        $payload = is_array($notification->payload) ? $notification->payload : [];
        $event = [
            'id' => $this->nextEventId('notification'),
            'event' => 'notification',
            'data' => [
                'notification' => [
                    'id' => $notification->notification_id ?: 'history-'.$notification->id,
                    'title' => $notification->title,
                    'message' => $notification->message,
                    'time' => $this->displayDate($notification->delivered_at ?? $notification->created_at),
                    'timestamp' => ($notification->delivered_at ?? $notification->created_at)?->toIso8601String(),
                    'category' => $notification->category ?: 'system',
                    'isRead' => $notification->read_at !== null,
                    'source' => 'sse',
                    'url' => $payload['url'] ?? '/notifications',
                    'tag' => $payload['tag'] ?? ($notification->notification_id ?: 'history-'.$notification->id),
                ],
                'unreadCount' => $this->unreadNotificationCount(),
            ],
        ];

        $this->storeEvent('notification', $event);

        return $event;
    }

    public function publishWriteBackJob(GeotabWriteJob $job): array
    {
        $payload = is_array($job->payload) ? $job->payload : [];
        $preview = is_array($job->preview_payload) ? $job->preview_payload : [];
        $event = [
            'id' => $this->nextEventId('writeback'),
            'event' => 'writeback',
            'data' => [
                'job' => [
                    'id' => (string) $job->id,
                    'action' => (string) $job->action,
                    'entityType' => (string) $job->entity_type,
                    'entityName' => (string) data_get($preview, 'entityName', data_get($payload, 'entity.name', data_get($payload, 'route.name', $job->entity_type))),
                    'localType' => (string) $job->local_type,
                    'localId' => $job->local_id !== null ? (string) $job->local_id : null,
                    'status' => (string) $job->status,
                    'syncStatus' => $this->syncStatusForJob($job),
                    'syncLabel' => $this->syncLabelForJob($job),
                    'lastError' => $job->last_error,
                    'pendingWriteJobId' => in_array($job->status, ['pending_approval', 'approved', 'processing', 'failed', 'permanently_failed'], true)
                        ? (string) $job->id
                        : null,
                    'processedAt' => $job->processed_at?->toIso8601String(),
                    'updatedAt' => $job->updated_at?->toIso8601String(),
                    'operations' => $this->writeBackOperations($payload),
                ],
            ],
        ];

        $this->storeEvent('writeback', $event);

        return $event;
    }

    public function latestEvent(string $channel): ?array
    {
        $event = match ($channel) {
            'live' => Cache::get(self::LIVE_EVENT_KEY),
            'notification' => Cache::get(self::NOTIFICATION_EVENT_KEY),
            'writeback' => Cache::get(self::WRITEBACK_EVENT_KEY),
            default => null,
        };

        return is_array($event) ? $event : null;
    }

    public function recentEvents(string $channel): array
    {
        $events = match ($channel) {
            'live' => Cache::get(self::LIVE_EVENT_LIST_KEY, []),
            'notification' => Cache::get(self::NOTIFICATION_EVENT_LIST_KEY, []),
            'writeback' => Cache::get(self::WRITEBACK_EVENT_LIST_KEY, []),
            default => [],
        };

        return is_array($events) ? array_values(array_filter($events, 'is_array')) : [];
    }

    public function heartbeatEvent(): array
    {
        return [
            'id' => $this->nextEventId('heartbeat'),
            'event' => 'heartbeat',
            'data' => [
                'serverTime' => now()->toIso8601String(),
            ],
        ];
    }

    private function vehicleFromDeviceStatusRow(array $row): ?array
    {
        $deviceId = trim((string) data_get($row, 'device.id', data_get($row, 'device')));
        $latitude = data_get($row, 'latitude');
        $longitude = data_get($row, 'longitude');
        if ($deviceId === '' || ! is_numeric($latitude) || ! is_numeric($longitude)) {
            return null;
        }

        $speed = (float) data_get($row, 'speed', 0);
        $dateTime = data_get($row, 'dateTime') ?: now()->toIso8601String();

        return [
            'geotabId' => $deviceId,
            'deviceGeotabId' => $deviceId,
            'plate' => data_get($row, 'device.name', $deviceId),
            'latitude' => round((float) $latitude, 6),
            'longitude' => round((float) $longitude, 6),
            'speed' => $speed,
            'bearing' => (float) data_get($row, 'bearing', 0),
            'isDriving' => data_get($row, 'isDriving') === true || $speed > 1.0,
            'ignitionOn' => data_get($row, 'isDriving') === true || $speed > 0,
            'lastGeotabAt' => $dateTime,
            'lastUpdated' => $dateTime,
            'syncState' => 'pushed',
        ];
    }

    private function storeEvent(string $channel, array $event): void
    {
        $latestKey = match ($channel) {
            'live' => self::LIVE_EVENT_KEY,
            'notification' => self::NOTIFICATION_EVENT_KEY,
            'writeback' => self::WRITEBACK_EVENT_KEY,
            default => self::LIVE_EVENT_KEY,
        };
        $listKey = match ($channel) {
            'live' => self::LIVE_EVENT_LIST_KEY,
            'notification' => self::NOTIFICATION_EVENT_LIST_KEY,
            'writeback' => self::WRITEBACK_EVENT_LIST_KEY,
            default => self::LIVE_EVENT_LIST_KEY,
        };
        $expiresAt = now()->addSeconds(self::EVENT_TTL_SECONDS);

        Cache::put($latestKey, $event, $expiresAt);

        $events = Cache::get($listKey, []);
        if (! is_array($events)) {
            $events = [];
        }

        $events[] = $event;
        $events = array_slice(array_values(array_filter($events, 'is_array')), -self::MAX_RECENT_EVENTS);
        Cache::put($listKey, $events, $expiresAt);
    }

    private function activeSseClientRows(): array
    {
        $clients = Cache::get(self::SSE_CLIENTS_KEY, []);
        if (! is_array($clients)) {
            return [];
        }

        $now = now();

        return collect($clients)
            ->filter(function (mixed $client) use ($now): bool {
                if (! is_array($client)) {
                    return false;
                }

                $expiresAt = $client['expiresAt'] ?? null;
                if (! is_string($expiresAt) || trim($expiresAt) === '') {
                    return false;
                }

                try {
                    return $now->lessThanOrEqualTo(Carbon::parse($expiresAt));
                } catch (\Throwable) {
                    return false;
                }
            })
            ->mapWithKeys(fn (array $client): array => [(string) ($client['clientId'] ?? Str::uuid()->toString()) => $client])
            ->all();
    }

    private function unreadNotificationCount(): int
    {
        try {
            return NotificationHistory::query()->whereNull('read_at')->count();
        } catch (\Throwable) {
            return 0;
        }
    }

    private function nextEventId(string $prefix): string
    {
        return $prefix.'-'.now()->format('YmdHisv').'-'.bin2hex(random_bytes(3));
    }

    private function syncStatusForJob(GeotabWriteJob $job): string
    {
        return match ((string) $job->status) {
            'succeeded' => 'synced',
            'pending_approval' => 'pending_approval',
            'approved', 'processing' => 'processing',
            'failed', 'rejected' => 'failed',
            'permanently_failed' => 'permanently_failed',
            default => (string) $job->status,
        };
    }

    private function syncLabelForJob(GeotabWriteJob $job): string
    {
        return match ($this->syncStatusForJob($job)) {
            'synced' => 'GeoTab: Up to date',
            'pending_approval' => 'GeoTab: Push awaiting approval',
            'processing' => 'GeoTab: Push approved, executing',
            'failed' => 'GeoTab: Sync failed',
            'permanently_failed' => 'GeoTab: Permanently failed',
            default => 'GeoTab: Never synced',
        };
    }

    private function writeBackOperations(array $payload): array
    {
        return collect((array) ($payload['operations'] ?? []))
            ->filter(fn ($operation): bool => is_array($operation))
            ->map(fn (array $operation): array => [
                'action' => (string) ($operation['action'] ?? ''),
                'localType' => (string) ($operation['localType'] ?? ''),
                'localId' => (string) ($operation['localId'] ?? ''),
                'entityType' => (string) ($operation['entityType'] ?? ''),
                'entityName' => (string) ($operation['entityName'] ?? ''),
            ])
            ->values()
            ->all();
    }

    private function displayDate(mixed $date): string
    {
        if ($date instanceof \DateTimeInterface) {
            return $date->diffForHumans();
        }

        return 'Just now';
    }
}
