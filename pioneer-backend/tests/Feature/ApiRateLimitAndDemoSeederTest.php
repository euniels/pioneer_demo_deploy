<?php

use App\Models\BillingInvoiceReference;
use App\Models\FleetClient;
use App\Models\FleetTrip;
use App\Models\ManualDriver;
use App\Models\ManualVehicle;
use App\Models\NotificationHistory;
use App\Models\ProofOfDelivery;
use Illuminate\Foundation\Testing\RefreshDatabase;

uses(RefreshDatabase::class);

test('rate limits are separated for reads live traffic login mutations and writeback', function (): void {
    config([
        'pioneer.rate_limits.login.max_attempts' => 2,
        'pioneer.rate_limits.reads.max_attempts' => 2,
        'pioneer.rate_limits.live.max_attempts' => 5,
        'pioneer.rate_limits.mutations.max_attempts' => 1,
        'pioneer.rate_limits.writeback.max_attempts' => 1,
    ]);

    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.1'])
        ->postJson('/api/fleet/users/login-check', ['username' => 'missing@example.test', 'password' => 'bad'])
        ->assertUnauthorized();
    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.1'])
        ->postJson('/api/fleet/users/login-check', ['username' => 'missing@example.test', 'password' => 'bad'])
        ->assertUnauthorized();
    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.1'])
        ->postJson('/api/fleet/users/login-check', ['username' => 'missing@example.test', 'password' => 'bad'])
        ->assertStatus(429)
        ->assertJsonPath('category', 'login');

    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.2'])->getJson('/api/fleet/summary')->assertOk();
    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.2'])->getJson('/api/fleet/summary')->assertOk();
    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.2'])
        ->getJson('/api/fleet/summary')
        ->assertStatus(429)
        ->assertJsonPath('category', 'reads')
        ->assertJsonStructure(['retryAfter']);

    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.2'])
        ->getJson('/api/fleet/summary/live')
        ->assertOk();

    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.3'])
        ->postJson('/api/fleet/clients', [])
        ->assertStatus(422);
    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.3'])
        ->postJson('/api/fleet/clients', [])
        ->assertStatus(429)
        ->assertJsonPath('category', 'mutations');

    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.4'])
        ->postJson('/api/fleet/geotab/writeback/jobs/999/approve', [])
        ->assertStatus(404);
    $this->withServerVariables(['REMOTE_ADDR' => '10.55.0.4'])
        ->postJson('/api/fleet/geotab/writeback/jobs/999/approve', [])
        ->assertStatus(429)
        ->assertJsonPath('category', 'writeback');
});

test('health exposes rate limit policy and recent api pressure', function (): void {
    config(['pioneer.rate_limits.reads.max_attempts' => 1]);

    $this->withServerVariables(['REMOTE_ADDR' => '10.55.1.1'])->getJson('/api/fleet/summary')->assertOk();
    $this->withServerVariables(['REMOTE_ADDR' => '10.55.1.1'])->getJson('/api/fleet/summary')->assertStatus(429);

    $payload = $this->getJson('/api/health')->assertOk()->json();

    expect(data_get($payload, 'rateLimits.reads.maxAttempts'))->toBe(1)
        ->and(data_get($payload, 'apiPressure.recent429Count'))->toBeGreaterThanOrEqual(1)
        ->and(data_get($payload, 'apiPressure.byCategory.reads.count'))->toBeGreaterThanOrEqual(1);
});

test('demo seeder creates a full client walkthrough data flow without duplicates', function (): void {
    $this->artisan('pioneer:demo-seed')->assertExitCode(0);
    $this->artisan('pioneer:demo-seed')->assertExitCode(0);

    expect(FleetClient::query()->where('company_name', 'like', 'Demo Client%')->count())->toBe(2)
        ->and(ManualVehicle::query()->where('plate_number', 'like', 'DEMO-TRK-%')->count())->toBe(3)
        ->and(ManualDriver::query()->where('name', 'like', 'Demo Driver%')->count())->toBe(3)
        ->and(FleetTrip::query()->where('trip_id', 'like', 'DEMO-TRIP-%')->count())->toBe(5)
        ->and(ProofOfDelivery::query()->where('trip_id', 'DEMO-TRIP-BILLED')->exists())->toBeTrue()
        ->and(BillingInvoiceReference::query()->where('trip_id', 'DEMO-TRIP-BILLED')->where('status', 'issued')->exists())->toBeTrue()
        ->and(NotificationHistory::query()->where('notification_id', 'like', 'demo-%')->count())->toBe(3);
});

test('demo seeder command is guarded in production unless forced', function (): void {
    $this->app->detectEnvironment(fn (): string => 'production');

    $this->artisan('pioneer:demo-seed')->assertExitCode(1);
});
