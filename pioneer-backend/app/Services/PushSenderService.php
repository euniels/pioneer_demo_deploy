<?php

namespace App\Services;

use App\Models\NotificationHistory;
use App\Models\PushSubscription;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Schema;
use Minishlink\WebPush\Subscription;
use Minishlink\WebPush\WebPush;

class PushSenderService
{
    public function send(NotificationHistory $notification): array
    {
        return $this->sendNotification($notification);
    }

    public function sendNotification(NotificationHistory $notification): array
    {
        if (! $this->isConfigured()) {
            Log::channel('app_errors')->warning('PioneerPath web push skipped because VAPID keys are not configured.', [
                'notificationId' => $notification->notification_id,
            ]);

            return $this->summary('skipped', 'VAPID keys are not configured.');
        }

        if (! $this->tableAvailable('push_subscriptions')) {
            return $this->summary('skipped', 'push_subscriptions table is not available.');
        }

        $subscriptions = PushSubscription::query()
            ->where('platform', 'web')
            ->orderBy('id')
            ->get();
        if ($subscriptions->isEmpty()) {
            return $this->summary('skipped', 'No web push subscriptions are registered.');
        }

        try {
            $webPush = $this->createWebPush();
        } catch (\Throwable $e) {
            Log::channel('app_errors')->warning('PioneerPath web push initialization failed', [
                'errorType' => get_class($e),
                'errorMessage' => $e->getMessage(),
            ]);

            return $this->summary('failed', $e->getMessage());
        }

        $queuedByEndpoint = [];
        $queueFailures = [];
        foreach ($subscriptions as $subscription) {
            try {
                $webPush->queueNotification(
                    $this->toWebPushSubscription($subscription),
                    $this->payloadFor($notification),
                    [
                        'TTL' => 3600,
                        'urgency' => 'normal',
                        'topic' => substr($notification->notification_id ?: 'pioneerpath', 0, 32),
                    ],
                );
                $queuedByEndpoint[$subscription->endpoint] = $subscription->endpoint_hash;
            } catch (\Throwable $e) {
                $queueFailures[] = [
                    'endpointHash' => $subscription->endpoint_hash,
                    'reason' => $e->getMessage(),
                ];
            }
        }

        $sent = 0;
        $failed = count($queueFailures);
        $expired = 0;
        $failures = $queueFailures;

        try {
            foreach ($webPush->flush() as $report) {
                $endpoint = method_exists($report, 'getEndpoint') ? $report->getEndpoint() : '';
                $endpointHash = $queuedByEndpoint[$endpoint] ?? ($endpoint !== '' ? hash('sha256', $endpoint) : null);

                if ($report->isSuccess()) {
                    $sent++;

                    continue;
                }

                $failed++;
                $reason = method_exists($report, 'getReason') ? $report->getReason() : 'Unknown web push failure.';
                $failures[] = [
                    'endpointHash' => $endpointHash,
                    'reason' => $reason,
                ];

                if ($endpointHash !== null && $this->isPermanentSubscriptionFailure($report, $reason)) {
                    PushSubscription::query()->where('endpoint_hash', $endpointHash)->delete();
                    $expired++;
                }
            }
        } catch (\Throwable $e) {
            $failed += max(1, count($queuedByEndpoint) - $sent);
            $failures[] = [
                'endpointHash' => null,
                'reason' => $e->getMessage(),
            ];
        }

        $summary = [
            'status' => $failed === 0 ? 'sent' : ($sent > 0 ? 'partial' : 'failed'),
            'reason' => null,
            'queued' => $subscriptions->count(),
            'sent' => $sent,
            'failed' => $failed,
            'expired' => $expired,
            'failures' => array_slice($failures, 0, 10),
        ];

        $this->recordNotificationResult($notification, $summary);

        Log::channel('notifications')->info('PioneerPath web push delivery finished', [
            'notificationId' => $notification->notification_id,
            ...$summary,
        ]);

        return $summary;
    }

    public function isConfigured(): bool
    {
        return trim((string) config('services.web_push.public_key', '')) !== ''
            && trim((string) config('services.web_push.private_key', '')) !== ''
            && trim((string) config('services.web_push.subject', '')) !== '';
    }

    protected function createWebPush(): mixed
    {
        return new WebPush([
            'VAPID' => [
                'subject' => (string) config('services.web_push.subject'),
                'publicKey' => (string) config('services.web_push.public_key'),
                'privateKey' => (string) config('services.web_push.private_key'),
            ],
        ], [
            'batchSize' => 100,
            'requestConcurrency' => 10,
        ], 15);
    }

    private function toWebPushSubscription(PushSubscription $subscription): Subscription
    {
        $meta = is_array($subscription->meta) ? $subscription->meta : [];
        $contentEncoding = trim((string) ($meta['contentEncoding'] ?? '')) ?: 'aesgcm';

        return Subscription::create([
            'endpoint' => $subscription->endpoint,
            'keys' => is_array($subscription->keys) ? $subscription->keys : [],
            'contentEncoding' => $contentEncoding,
        ]);
    }

    private function payloadFor(NotificationHistory $notification): string
    {
        $payload = is_array($notification->payload) ? $notification->payload : [];
        $url = (string) ($payload['url'] ?? $payload['deepLink'] ?? '/notifications');

        return (string) json_encode([
            'title' => $notification->title ?: 'PioneerPath',
            'body' => $notification->message ?: 'New fleet notification',
            'message' => $notification->message,
            'url' => $url,
            'icon' => (string) ($payload['icon'] ?? '/icons/Icon-192.png'),
            'tag' => (string) ($payload['tag'] ?? $notification->notification_id ?? 'pioneerpath'),
            'data' => [
                'notificationId' => $notification->notification_id,
                'category' => $notification->category,
                'url' => $url,
                'payload' => $payload,
            ],
        ]);
    }

    private function recordNotificationResult(NotificationHistory $notification, array $summary): void
    {
        $payload = is_array($notification->payload) ? $notification->payload : [];
        $values = [
            'status' => $summary['status'],
            'payload' => [
                ...$payload,
                'webPush' => [
                    'status' => $summary['status'],
                    'queued' => $summary['queued'],
                    'sent' => $summary['sent'],
                    'failed' => $summary['failed'],
                    'expired' => $summary['expired'],
                    'checkedAt' => now()->toIso8601String(),
                ],
            ],
        ];

        if ($this->columnAvailable('notification_histories', 'delivery_attempts')) {
            $values['delivery_attempts'] = ((int) ($notification->delivery_attempts ?? 0)) + (int) ($summary['queued'] ?? 0);
        }

        if ($this->columnAvailable('notification_histories', 'last_delivery_at')) {
            $values['last_delivery_at'] = now();
        }

        $notification->forceFill($values)->save();
    }

    private function isPermanentSubscriptionFailure(mixed $report, string $reason): bool
    {
        if (method_exists($report, 'isSubscriptionExpired') && $report->isSubscriptionExpired()) {
            return true;
        }

        return str_contains($reason, '410') || str_contains($reason, '404');
    }

    private function summary(string $status, string $reason): array
    {
        return [
            'status' => $status,
            'reason' => $reason,
            'queued' => 0,
            'sent' => 0,
            'failed' => 0,
            'expired' => 0,
            'failures' => [],
        ];
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
}
