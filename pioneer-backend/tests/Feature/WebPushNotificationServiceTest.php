<?php

use App\Models\NotificationHistory;
use App\Models\PushSubscription;
use App\Services\PushSenderService;
use Illuminate\Foundation\Testing\RefreshDatabase;

uses(RefreshDatabase::class);

test('web push sender skips when VAPID is missing', function () {
    config([
        'services.web_push.public_key' => '',
        'services.web_push.private_key' => '',
        'services.web_push.subject' => 'mailto:admin@example.com',
    ]);

    $notification = NotificationHistory::query()->create([
        'notification_id' => 'test-no-vapid',
        'title' => 'Test',
        'message' => 'Missing VAPID',
        'category' => 'system',
        'status' => 'sent',
        'audience' => 'internal',
        'delivered_at' => now(),
    ]);

    $summary = (new PushSenderService)->send($notification);

    expect($summary['status'])->toBe('skipped')
        ->and($summary['reason'])->toBe('VAPID keys are not configured.');
});

test('web push sender attempts delivery when VAPID and subscriptions exist', function () {
    config([
        'services.web_push.public_key' => 'public-key',
        'services.web_push.private_key' => 'private-key',
        'services.web_push.subject' => 'mailto:admin@example.com',
    ]);

    PushSubscription::query()->create([
        'endpoint_hash' => hash('sha256', 'https://push.example.test/ok'),
        'endpoint' => 'https://push.example.test/ok',
        'platform' => 'web',
        'keys' => ['p256dh' => 'client-key', 'auth' => 'auth-token'],
        'meta' => ['contentEncoding' => 'aes128gcm'],
        'last_seen_at' => now(),
    ]);
    $notification = NotificationHistory::query()->create([
        'notification_id' => 'test-web-push-ok',
        'title' => 'Test',
        'message' => 'Delivery attempt',
        'category' => 'system',
        'status' => 'sent',
        'audience' => 'internal',
        'payload' => [],
        'delivered_at' => now(),
    ]);

    $service = new class extends PushSenderService
    {
        public FakeWebPush $fake;

        protected function createWebPush(): mixed
        {
            return $this->fake = new FakeWebPush([
                new FakeWebPushReport('https://push.example.test/ok', true),
            ]);
        }
    };

    $summary = $service->sendNotification($notification);

    expect($summary['status'])->toBe('sent')
        ->and($summary['sent'])->toBe(1)
        ->and($service->fake->queued)->toHaveCount(1)
        ->and($notification->refresh()->payload['webPush']['sent'])->toBe(1)
        ->and($notification->delivery_attempts)->toBe(1)
        ->and($notification->last_delivery_at)->not->toBeNull();
});

test('web push sender removes expired subscriptions', function () {
    config([
        'services.web_push.public_key' => 'public-key',
        'services.web_push.private_key' => 'private-key',
        'services.web_push.subject' => 'mailto:admin@example.com',
    ]);

    PushSubscription::query()->create([
        'endpoint_hash' => hash('sha256', 'https://push.example.test/expired'),
        'endpoint' => 'https://push.example.test/expired',
        'platform' => 'web',
        'keys' => ['p256dh' => 'client-key', 'auth' => 'auth-token'],
        'meta' => ['contentEncoding' => 'aes128gcm'],
        'last_seen_at' => now(),
    ]);
    $notification = NotificationHistory::query()->create([
        'notification_id' => 'test-web-push-expired',
        'title' => 'Test',
        'message' => 'Expired endpoint',
        'category' => 'system',
        'status' => 'sent',
        'audience' => 'internal',
        'payload' => [],
        'delivered_at' => now(),
    ]);

    $service = new class extends PushSenderService
    {
        protected function createWebPush(): mixed
        {
            return new FakeWebPush([
                new FakeWebPushReport('https://push.example.test/expired', false, true, '410 Gone'),
            ]);
        }
    };

    $summary = $service->sendNotification($notification);

    expect($summary['status'])->toBe('failed')
        ->and($summary['expired'])->toBe(1)
        ->and(PushSubscription::query()->count())->toBe(0);
});

test('web push sender continues after a transient failure', function () {
    config([
        'services.web_push.public_key' => 'public-key',
        'services.web_push.private_key' => 'private-key',
        'services.web_push.subject' => 'mailto:admin@example.com',
    ]);

    foreach (['https://push.example.test/fail', 'https://push.example.test/ok'] as $endpoint) {
        PushSubscription::query()->create([
            'endpoint_hash' => hash('sha256', $endpoint),
            'endpoint' => $endpoint,
            'platform' => 'web',
            'keys' => ['p256dh' => 'client-key', 'auth' => 'auth-token'],
            'meta' => ['contentEncoding' => 'aes128gcm'],
            'last_seen_at' => now(),
        ]);
    }

    $notification = NotificationHistory::query()->create([
        'notification_id' => 'test-web-push-transient',
        'title' => 'Test',
        'message' => 'Transient failure',
        'category' => 'system',
        'status' => 'sent',
        'audience' => 'internal',
        'payload' => [],
        'delivered_at' => now(),
    ]);

    $service = new class extends PushSenderService
    {
        public FakeWebPush $fake;

        protected function createWebPush(): mixed
        {
            return $this->fake = new FakeWebPush([
                new FakeWebPushReport('https://push.example.test/fail', false, false, '500 Internal Server Error'),
                new FakeWebPushReport('https://push.example.test/ok', true),
            ]);
        }
    };

    $summary = $service->sendNotification($notification);

    expect($summary['status'])->toBe('partial')
        ->and($summary['sent'])->toBe(1)
        ->and($summary['failed'])->toBe(1)
        ->and($service->fake->queued)->toHaveCount(2)
        ->and(collect($service->fake->queued)->map(
            fn (array $queued): string => $queued['subscription']->getEndpoint()
        )->all())->toBe([
            'https://push.example.test/fail',
            'https://push.example.test/ok',
        ])
        ->and(PushSubscription::query()->count())->toBe(2);
});

class FakeWebPush
{
    public array $queued = [];

    public function __construct(private readonly array $reports) {}

    public function queueNotification(mixed $subscription, ?string $payload = null, array $options = []): void
    {
        $this->queued[] = compact('subscription', 'payload', 'options');
    }

    public function flush(): Generator
    {
        foreach ($this->reports as $report) {
            yield $report;
        }
    }
}

class FakeWebPushReport
{
    public function __construct(
        private readonly string $endpoint,
        private readonly bool $success,
        private readonly bool $expired = false,
        private readonly string $reason = 'OK',
    ) {}

    public function getEndpoint(): string
    {
        return $this->endpoint;
    }

    public function isSuccess(): bool
    {
        return $this->success;
    }

    public function isSubscriptionExpired(): bool
    {
        return $this->expired;
    }

    public function getReason(): string
    {
        return $this->reason;
    }
}
