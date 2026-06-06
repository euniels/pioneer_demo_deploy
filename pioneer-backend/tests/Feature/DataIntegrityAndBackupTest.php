<?php

use App\Models\BillingInvoiceReference;
use App\Models\FleetClient;
use App\Models\GeotabFeedCheckpoint;
use App\Models\GeotabWriteJob;
use App\Models\GpsLog;
use App\Models\ManualDriver;
use App\Models\ManualVehicle;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\File;

uses(RefreshDatabase::class);

function integritySeedSnapshot(array $overrides = []): void
{
    $snapshot = array_replace_recursive([
        'vehicles' => [],
        'drivers' => [],
        'trips' => [],
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
        'fuel' => [
            'transactions' => [],
            'chargeEvents' => [],
        ],
        'telemetry' => [
            'assets' => [],
        ],
        'temperature' => [],
        'compliance' => [],
        'reports' => [
            'unmatchedRoutes' => [],
            'driverCongregation' => [],
        ],
        'lastSyncedAt' => now()->toIso8601String(),
    ], $overrides);

    Cache::put('geotab_fleet_snapshot_v4_fresh', $snapshot, now()->addMinutes(10));
    Cache::put('geotab_fleet_snapshot_v4_stale', $snapshot, now()->addMinutes(30));
}

it('passes backup check when a recent mysql dump exists', function (): void {
    $path = storage_path('framework/testing-backups');
    File::ensureDirectoryExists($path);
    File::put($path.'/pioneerpath-'.now()->toDateString().'.sql.gz', 'backup-bytes');

    config()->set('pioneer.backups.path', $path);
    config()->set('pioneer.backups.max_age_hours', 25);

    $this->artisan('pioneer:backup-check')
        ->assertExitCode(0);

    File::deleteDirectory($path);
});

it('reports stale or missing backups and creates an operational alert', function (): void {
    $path = storage_path('framework/testing-missing-backups');
    File::deleteDirectory($path);

    config()->set('pioneer.backups.path', $path);

    $this->artisan('pioneer:backup-check')
        ->assertExitCode(1);

    $this->assertDatabaseHas('notification_histories', [
        'category' => 'system',
        'audience' => 'super_administrator',
        'title' => 'Backup Check Failed',
    ]);
});

it('reports invoice gps writeback and active trip tracking anomalies without modifying data', function (): void {
    integritySeedSnapshot([
        'trips' => [
            [
                'tripId' => 'TRP-ACTIVE-INTEGRITY',
                'status' => 'in transit',
                'vehicle' => 'PTC-100',
                'deviceGeotabId' => 'device-integrity',
            ],
        ],
    ]);

    GeotabFeedCheckpoint::query()->create([
        'type_name' => 'LogRecord',
        'cursor' => 'cursor-1',
        'seeded_at' => now()->subDay(),
        'last_success_at' => now()->subMinutes(5),
    ]);
    BillingInvoiceReference::query()->create([
        'trip_id' => 'TRP-MISSING-INVOICE',
        'invoice_number' => 'INV-MISSING',
        'status' => 'issued',
    ]);
    GpsLog::query()->create([
        'trip_id' => 'TRP-MISSING-GPS',
        'geotab_log_id' => 'log-missing-gps',
        'device_geotab_id' => 'device-orphan',
        'latitude' => 14.5995,
        'longitude' => 120.9842,
        'recorded_at' => now()->subHours(2),
    ]);
    GeotabWriteJob::query()->create([
        'action' => 'route.create',
        'entity_type' => 'Route',
        'local_type' => 'fleet_route',
        'local_id' => 'route-stale',
        'payload' => ['entity' => ['name' => 'Stale route']],
        'status' => 'approved',
        'created_at' => now()->subDays(2),
        'updated_at' => now()->subDays(2),
    ]);

    $this->artisan('pioneer:integrity-check')
        ->assertExitCode(1);

    expect(BillingInvoiceReference::query()->count())->toBe(1)
        ->and(GpsLog::query()->count())->toBe(1)
        ->and(GeotabWriteJob::query()->where('status', 'approved')->count())->toBe(1);
});

it('excludes deactivated records from active operational filters', function (): void {
    FleetClient::query()->create([
        'company_name' => 'Active Client',
        'contact_person_name' => 'Ana',
        'contact_number' => '09170000000',
        'billing_address' => 'Cabuyao',
        'status' => 'active',
    ]);
    FleetClient::query()->create([
        'company_name' => 'Inactive Client',
        'contact_person_name' => 'Ben',
        'contact_number' => '09170000001',
        'billing_address' => 'Cabuyao',
        'status' => 'inactive',
        'deactivated_at' => now(),
    ]);
    ManualDriver::query()->create(['name' => 'Active Driver', 'status' => 'available']);
    ManualDriver::query()->create(['name' => 'Inactive Driver', 'status' => 'inactive']);
    ManualVehicle::query()->create([
        'plate_number' => 'PTC-ACTIVE',
        'vehicle_type' => 'Drop-side Truck',
        'fuel_type' => 'Diesel',
        'cargo_capacity_kg' => 2500,
        'registration_expiry_date' => now()->addYear()->toDateString(),
        'status' => 'active',
    ]);
    ManualVehicle::query()->create([
        'plate_number' => 'PTC-INACTIVE',
        'vehicle_type' => 'Drop-side Truck',
        'fuel_type' => 'Diesel',
        'cargo_capacity_kg' => 2500,
        'registration_expiry_date' => now()->addYear()->toDateString(),
        'status' => 'inactive',
        'deactivated_at' => now(),
    ]);

    $clients = $this->getJson('/api/fleet/clients?status=active')->assertOk()->json('data');
    $drivers = $this->getJson('/api/fleet/drivers/manual?status=active')->assertOk()->json('data');
    $vehicles = $this->getJson('/api/fleet/vehicles/manual?status=active')->assertOk()->json('data');

    expect(collect($clients)->pluck('companyName'))->toContain('Active Client')->not->toContain('Inactive Client')
        ->and(collect($drivers)->pluck('name'))->toContain('Active Driver')->not->toContain('Inactive Driver')
        ->and(collect($vehicles)->pluck('plate'))->toContain('PTC-ACTIVE')->not->toContain('PTC-INACTIVE');
});

it('excludes voided invoices from outstanding balance calculations', function (): void {
    integritySeedSnapshot([
        'billings' => [
            [
                'tripId' => 'TRP-VOIDED-SOA',
                'invoiceNumber' => 'INV-VOIDED-SOA',
                'client' => 'SOA Client',
                'amount' => 'PHP 5,000.00',
                'status' => 'issued',
                'issueDate' => now()->toDateString(),
            ],
        ],
    ]);

    BillingInvoiceReference::query()->create([
        'trip_id' => 'TRP-VOIDED-SOA',
        'invoice_number' => 'INV-VOIDED-SOA',
        'status' => 'voided',
        'voided_at' => now(),
        'void_reason' => 'Duplicate ERP entry.',
    ]);

    $soa = $this->getJson('/api/billing/soa')
        ->assertOk()
        ->json('data');

    $client = collect($soa['clients'])->firstWhere('name', 'SOA Client');
    expect((float) $client['outstanding'])->toBe(0.0)
        ->and($client['outstandingLabel'])->toBe('PHP 0.00');
});
