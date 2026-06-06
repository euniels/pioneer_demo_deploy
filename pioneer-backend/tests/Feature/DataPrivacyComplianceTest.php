<?php

use App\Models\GeotabFeedRow;
use App\Models\GpsLog;
use App\Models\ManualDriver;
use App\Models\SystemSetting;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Tests\TestCase;

uses(RefreshDatabase::class);

function privacyUser(string $role, array $overrides = []): User
{
    return User::query()->create([
        'name' => $overrides['name'] ?? 'Privacy User',
        'email' => $overrides['email'] ?? $role.'@privacy.test',
        'password' => Hash::make('SecurePass123!'),
        'role' => $role,
        'status' => 'active',
        'must_change_password' => false,
    ]);
}

function privacyTokenFor(TestCase $test, User $user): string
{
    return (string) $test->postJson('/api/fleet/users/login-check', [
        'username' => $user->email,
        'password' => 'SecurePass123!',
        'platform' => 'web',
    ])->assertOk()->json('data.auth.accessToken');
}

function privacySeedSnapshot(array $trips): void
{
    $snapshot = [
        'vehicles' => [],
        'drivers' => [],
        'trips' => $trips,
        'routes' => [],
        'zones' => [],
        'dashboard' => [],
        'billings' => [],
        'billingOverview' => [],
        'soa' => ['clients' => []],
        'maintenance' => [],
        'maintenanceOverview' => [],
        'maintenanceFaults' => [],
        'maintenanceDvir' => [],
        'maintenanceWorkOrders' => [],
        'fuel' => ['transactions' => [], 'chargeEvents' => []],
        'telemetry' => ['assets' => []],
        'temperature' => [],
        'compliance' => [],
        'reports' => ['unmatchedRoutes' => [], 'driverCongregation' => []],
        'lastSyncedAt' => now()->toIso8601String(),
    ];

    Cache::put('geotab_fleet_snapshot_v4_fresh', $snapshot, now()->addMinutes(10));
}

test('location history is restricted by role and driver ownership', function (): void {
    privacySeedSnapshot([
        [
            'tripId' => 'TRP-PRIVACY-OWN',
            'status' => 'completed',
            'driver' => 'Driver Privacy',
            'vehicle' => 'PTC-001',
            'phone' => '09171234567',
            'clientEmail' => 'client.privacy@test.local',
        ],
        [
            'tripId' => 'TRP-PRIVACY-OTHER',
            'status' => 'completed',
            'driver' => 'Other Driver',
            'vehicle' => 'PTC-002',
        ],
    ]);

    $driver = privacyUser('driver', ['name' => 'Driver Privacy']);
    $driverToken = privacyTokenFor($this, $driver);
    $accounting = privacyUser('accounting_staff', ['email' => 'privacy.accounting@test.local']);
    $accountingToken = privacyTokenFor($this, $accounting);

    $this->withToken($driverToken)
        ->getJson('/api/fleet/trips/TRP-PRIVACY-OTHER/map')
        ->assertForbidden();

    $this->withToken($driverToken)
        ->getJson('/api/fleet/trips')
        ->assertOk()
        ->assertJsonPath('data.0.tripId', 'TRP-PRIVACY-OWN')
        ->assertJsonPath('data.0.phone', 'Hidden for privacy')
        ->assertJsonPath('data.0.clientEmail', 'Hidden for privacy');

    $this->withToken($driverToken)
        ->getJson('/api/fleet/client-tracking/TRP-PRIVACY-OWN')
        ->assertOk();

    $this->withToken($accountingToken)
        ->getJson('/api/fleet/trips/TRP-PRIVACY-OWN/map')
        ->assertForbidden();
});

test('retention settings can be saved and returned from system settings', function (): void {
    $admin = privacyUser('super_administrator', ['email' => 'privacy.admin@test.local']);
    $token = privacyTokenFor($this, $admin);

    $this->withToken($token)->putJson('/api/fleet/settings/system', [
        'gpsLogRetentionDays' => 120,
        'rawGeotabFeedRetentionDays' => 45,
        'notificationHistoryRetentionDays' => 100,
        'auditLogRetentionDays' => 400,
    ])->assertOk()
        ->assertJsonPath('data.gpsLogRetentionDays', 120)
        ->assertJsonPath('data.rawGeotabFeedRetentionDays', 45)
        ->assertJsonPath('data.notificationHistoryRetentionDays', 100)
        ->assertJsonPath('data.auditLogRetentionDays', 400);

    expect(SystemSetting::query()->first()?->gps_log_retention_days)->toBe(120);
});

test('feed prune command respects configured privacy retention windows', function (): void {
    SystemSetting::query()->create([
        'gps_log_retention_days' => 90,
        'raw_geotab_feed_retention_days' => 45,
        'notification_history_retention_days' => 90,
        'audit_log_retention_days' => 365,
    ]);

    GeotabFeedRow::query()->create([
        'type_name' => 'LogRecord',
        'geotab_id' => 'old-feed-row',
        'device_geotab_id' => 'device-privacy',
        'recorded_at' => now()->subDays(50),
        'payload_hash' => hash('sha256', 'old-feed-row'),
        'payload' => ['id' => 'old-feed-row'],
    ]);
    GeotabFeedRow::query()->create([
        'type_name' => 'LogRecord',
        'geotab_id' => 'fresh-feed-row',
        'device_geotab_id' => 'device-privacy',
        'recorded_at' => now()->subDays(20),
        'payload_hash' => hash('sha256', 'fresh-feed-row'),
        'payload' => ['id' => 'fresh-feed-row'],
    ]);

    GpsLog::query()->create([
        'trip_id' => 'TRP-PRIVACY-OLD',
        'geotab_log_id' => 'old-gps-row',
        'device_geotab_id' => 'device-privacy',
        'latitude' => 14.1234567,
        'longitude' => 121.1234567,
        'recorded_at' => now()->subDays(100),
    ]);
    GpsLog::query()->create([
        'trip_id' => 'TRP-PRIVACY-FRESH',
        'geotab_log_id' => 'fresh-gps-row',
        'device_geotab_id' => 'device-privacy',
        'latitude' => 14.2234567,
        'longitude' => 121.2234567,
        'recorded_at' => now()->subDays(80),
    ]);

    DB::table('notification_histories')->insert([
        [
            'notification_id' => 'old-notification-row',
            'title' => 'Old notification',
            'message' => 'Old notification',
            'category' => 'system',
            'status' => 'sent',
            'audience' => 'internal',
            'created_at' => now()->subDays(100),
            'updated_at' => now()->subDays(100),
        ],
        [
            'notification_id' => 'fresh-notification-row',
            'title' => 'Fresh notification',
            'message' => 'Fresh notification',
            'category' => 'system',
            'status' => 'sent',
            'audience' => 'internal',
            'created_at' => now()->subDays(60),
            'updated_at' => now()->subDays(60),
        ],
    ]);

    $this->artisan('geotab:feed-prune')->assertExitCode(0);

    $this->assertDatabaseMissing('geotab_feed_rows', ['geotab_id' => 'old-feed-row']);
    $this->assertDatabaseHas('geotab_feed_rows', ['geotab_id' => 'fresh-feed-row']);
    $this->assertDatabaseMissing('gps_logs', ['geotab_log_id' => 'old-gps-row']);
    $this->assertDatabaseHas('gps_logs', ['geotab_log_id' => 'fresh-gps-row']);
    $this->assertDatabaseMissing('notification_histories', ['notification_id' => 'old-notification-row']);
    $this->assertDatabaseHas('notification_histories', ['notification_id' => 'fresh-notification-row']);
});

test('super administrator can anonymize deactivated manual driver profile data', function (): void {
    $admin = privacyUser('super_administrator', ['email' => 'privacy.driver.admin@test.local']);
    $token = privacyTokenFor($this, $admin);
    $driver = ManualDriver::query()->create([
        'name' => 'Anonymize Driver',
        'license' => 'N01-22-333333',
        'phone' => '09170000000',
        'email' => 'driver.privacy@test.local',
        'status' => 'inactive',
        'meta' => [
            'address' => 'Cabuyao, Laguna',
            'emergencyContact' => 'Emergency Contact',
        ],
    ]);

    $this->withToken($token)
        ->postJson('/api/fleet/drivers/manual/'.$driver->id.'/anonymize', [
            'reason' => 'Driver privacy request.',
        ])
        ->assertOk()
        ->assertJsonPath('data.license', 'N/A')
        ->assertJsonPath('data.phone', 'N/A')
        ->assertJsonPath('data.email', 'N/A')
        ->assertJsonPath('data.address', 'N/A')
        ->assertJsonPath('data.emergencyContact', 'N/A');
});
