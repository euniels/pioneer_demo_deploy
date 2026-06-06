<?php

use App\Models\BillingInvoiceReference;
use App\Models\ClientVehicleAssignment;
use App\Models\FleetTrip;
use App\Models\GeotabFeedRow;
use App\Models\GeotabWriteJob;
use App\Models\MaintenanceHistory;
use App\Models\ManualDriver;
use App\Models\NotificationHistory;
use App\Models\SystemSetting;
use App\Services\GeotabService;
use Carbon\CarbonInterface;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;

uses(RefreshDatabase::class);

function billingVerifiedPodPayload(): array
{
    return [
        'recipientName' => 'Accounting Test Receiver',
        'status' => 'delivered',
        'signatureDataUrl' => 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
    ];
}

test('fuel price settings can be saved and returned for estimates', function () {
    $this->putJson('/api/fleet/settings/fuel-prices', [
        'dieselPricePerLiter' => 63.45,
        'gasolinePricePerLiter' => 72.10,
        'vatRatePercent' => 12,
        'priceSourceLabel' => 'DOE April 2026 Week 3',
    ])
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.dieselPricePerLiter', 63.45)
        ->assertJsonPath('data.gasolinePricePerLiter', 72.10)
        ->assertJsonPath('data.vatRatePercent', 12)
        ->assertJsonPath('data.priceSourceLabel', 'DOE April 2026 Week 3')
        ->assertJsonPath('data.configured', true);

    expect(SystemSetting::query()->count())->toBe(1);
});

test('system settings can be configured audited and applied to billing and maps', function () {
    $this->putJson('/api/fleet/settings/system', [
        'actor' => 'super.admin@example.test',
        'freeDeliveryThreshold' => 150000,
        'vatRatePercent' => 10,
        'baseDeliveryChargePerKm' => 80,
        'fuelSurchargeRatePercent' => 20,
        'dieselPricePerLiter' => 64.5,
        'gasolinePricePerLiter' => 72.25,
        'priceSourceLabel' => 'Manual May 2026',
        'geotabServerUrl' => 'https://my.geotab.com',
        'geotabUsername' => 'service@example.test',
        'geotabCompanyGroupId' => 'GroupPioneerCompanyId',
        'feedSeedWindowDays' => 45,
        'feedSyncIntervalMinutes' => 3,
        'gpsTrailMaxPoints' => 250,
        'humidityAlertMinPercent' => 10,
        'humidityAlertMaxPercent' => 80,
        'idleTimeAlertThresholdMinutes' => 25,
        'maintenanceDueWarningDays' => 21,
        'registrationExpiryWarningDays' => 45,
        'licenseExpiryWarningDays' => 35,
        'depotLatitude' => 14.22,
        'depotLongitude' => 121.10,
        'defaultMapCenterLatitude' => 14.5995,
        'defaultMapCenterLongitude' => 120.9842,
    ])
        ->assertOk()
        ->assertJsonPath('data.freeDeliveryThreshold', 150000)
        ->assertJsonPath('data.vatRatePercent', 10)
        ->assertJsonPath('data.baseDeliveryChargePerKm', 80)
        ->assertJsonPath('data.fuelSurchargeRatePercent', 20)
        ->assertJsonPath('data.geotabUsername', 'service@example.test')
        ->assertJsonPath('data.geotabCompanyGroupId', 'GroupPioneerCompanyId')
        ->assertJsonPath('data.feedSeedWindowDays', 45)
        ->assertJsonPath('data.gpsTrailMaxPoints', 250)
        ->assertJsonPath('data.depotLatitude', 14.22);

    expect(SystemSetting::query()->first()?->audit_log)->not->toBeEmpty();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-SYSTEM-SETTINGS',
        'customer' => 'Settings Client',
        'origin' => 'Pioneer Warehouse',
        'destination' => 'Client Site',
        'amount' => 10000,
        'orderValue' => 120000,
        'distanceKm' => 10,
        'status' => 'completed',
    ])->assertOk()->assertJsonPath('data.freeDeliveryCandidate', false);

    $invoice = collect($this->getJson('/api/billing/invoices')->assertOk()->json('data.invoices'))
        ->firstWhere('tripId', 'TRP-SYSTEM-SETTINGS');

    expect($invoice)->not->toBeNull()
        ->and((float) $invoice['baseDeliveryChargePerKm'])->toBe(80.0)
        ->and((float) $invoice['fuelSurchargeRatePercent'])->toBe(20.0)
        ->and((float) $invoice['vatRatePercent'])->toBe(10.0)
        ->and((float) $invoice['freeDeliveryThreshold'])->toBe(150000.0);
});

test('system settings reject invalid percentage ranges', function () {
    $this->putJson('/api/fleet/settings/system', [
        'humidityAlertMinPercent' => 90,
        'humidityAlertMaxPercent' => 70,
    ])->assertStatus(422);

    $this->putJson('/api/fleet/settings/system', [
        'vatRatePercent' => 120,
    ])->assertUnprocessable();
});

test('fuel payload includes saved price settings and estimated cost output', function () {
    Cache::flush();

    SystemSetting::query()->create([
        'diesel_price_per_liter' => 63.45,
        'gasoline_price_per_liter' => 72.10,
        'price_source_label' => 'DOE April 2026 Week 3',
        'price_last_updated' => now(),
    ]);

    $geotab = new class extends GeotabService
    {
        public function isConfigured(): bool
        {
            return true;
        }

        public function getDevices(): array
        {
            return [[
                'id' => 'device-fuel',
                'name' => 'TRK-FUEL',
                'licensePlate' => 'TRK-FUEL',
            ]];
        }

        public function getDeviceStatusInfo(array $diagnostics = []): array
        {
            return [];
        }

        public function getDrivers(): array
        {
            return [];
        }

        public function getZones(?CarbonInterface $activeAt = null, int $limit = 500): array
        {
            return [];
        }

        public function getRoutes(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [];
        }

        public function getTrips(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [];
        }

        public function getDutyStatusLogs(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [];
        }

        public function getFillUps(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 200): array
        {
            return [[
                'id' => 'fill-up-1',
                'device' => ['id' => 'device-fuel'],
                'dateTime' => '2026-04-20T10:00:00Z',
                'volume' => 10,
                'cost' => 0,
                'vendorName' => '',
            ]];
        }

        public function getFuelAndEnergyUsed(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [];
        }

        public function getFuelTransactions(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 500): array
        {
            return [[
                'id' => 'fuel-transaction-1',
                'device' => ['id' => 'device-fuel'],
                'dateTime' => '2026-04-20T11:00:00Z',
                'volume' => 5,
                'cost' => 0,
                'siteName' => '',
                'productType' => 'diesel',
            ]];
        }

        public function getChargeEvents(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [];
        }

        public function getExceptionEvents(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [];
        }

        public function getFaultData(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [];
        }

        public function getDvirLogs(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [];
        }

        public function getDriverChanges(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 500): array
        {
            return [];
        }

        public function getShipmentLogs(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [];
        }

        public function getIoxAddOns(?string $deviceId = null, ?int $type = null, int $limit = 250): array
        {
            return [];
        }
    };
    app()->instance(GeotabService::class, $geotab);

    $this->getJson('/api/fleet/fuel')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.priceSettings.configured', true)
        ->assertJsonPath('data.priceSettings.vatRatePercent', 12)
        ->assertJsonPath('data.priceSettings.priceSourceLabel', 'DOE April 2026 Week 3')
        ->assertJsonPath('data.events.0.estimatedCost', 634.5)
        ->assertJsonPath('data.events.0.estimatedCostLabel', 'PHP 634.50')
        ->assertJsonPath('data.transactions.0.estimatedCost', 317.25)
        ->assertJsonPath('data.transactions.0.estimatedCostLabel', 'PHP 317.25');

    $this->getJson('/api/fleet/fuel?vehicle=TRK-FUEL')
        ->assertOk()
        ->assertJsonCount(1, 'data.events')
        ->assertJsonCount(1, 'data.transactions');
    $this->getJson('/api/fleet/fuel/transactions?vehicle=device-fuel')
        ->assertOk()
        ->assertJsonCount(1, 'data');
    $this->getJson('/api/fleet/fuel?vehicle=OTHER-UNIT')
        ->assertOk()
        ->assertJsonCount(0, 'data.events')
        ->assertJsonCount(0, 'data.transactions');
});

test('manual driver list payload does not expose salary fields', function () {
    ManualDriver::query()->create([
        'name' => 'Salary Hidden Driver',
        'license' => 'ABC-123',
        'phone' => '09170000000',
        'email' => 'driver@example.test',
        'status' => 'available',
        'base_salary' => 30000,
        'per_trip_bonus' => 500,
    ]);

    $response = $this->getJson('/api/fleet/drivers/manual')
        ->assertOk()
        ->assertJsonPath('success', true);

    $driver = $response->json('data.0');
    expect($driver)->not->toHaveKeys(['baseSalary', 'perTripBonus']);
});

test('maintenance logs support manual crud proof supplements and voiding', function () {
    $created = $this->postJson('/api/fleet/maintenance/history', [
        'vehicleGeotabId' => 'device-maint-1',
        'vehiclePlate' => 'PTC-888',
        'recordedAt' => now()->toIso8601String(),
        'nextDueAt' => now()->addMonths(3)->toIso8601String(),
        'odometerKm' => 12500,
        'type' => 'Preventive Maintenance Service',
        'description' => 'PMS completed. Brakes checked and filters inspected.',
        'provider' => 'Internal workshop',
        'cost' => 7500,
        'notes' => 'C3-04 remarks recorded.',
        'proofFileName' => 'pms-proof.pdf',
        'proofFileType' => 'application/pdf',
        'proofDataUrl' => 'data:application/pdf;base64,JVBERi0xLjQKJSVFT0Y=',
    ])
        ->assertOk()
        ->assertJsonPath('data.vehiclePlate', 'PTC-888')
        ->assertJsonPath('data.odometerKm', 12500)
        ->assertJsonPath('data.hasProof', true)
        ->assertJsonPath('data.syncStatus', 'local_modified');

    $historyId = $created->json('data.id');
    expect(GeotabWriteJob::query()
        ->where('local_type', 'maintenance_history')
        ->where('action', 'maintenance.reminder')
        ->count())->toBe(0);

    $this->postJson('/api/fleet/maintenance/history/'.$historyId.'/push-geotab', ['previewOnly' => true])
        ->assertOk()
        ->assertJsonPath('data.previewOnly', true);

    expect(GeotabWriteJob::query()->where('local_type', 'maintenance_history')->where('action', 'maintenance.reminder')->count())->toBe(0);

    $this->postJson('/api/fleet/maintenance/history/'.$historyId.'/push-geotab')
        ->assertOk()
        ->assertJsonPath('data.syncStatus', 'pending_approval');

    expect(GeotabWriteJob::query()->where('local_type', 'maintenance_history')->where('action', 'maintenance.reminder')->count())->toBe(1);

    MaintenanceHistory::query()->create([
        'vehicle_geotab_id' => 'device-maint-geotab',
        'vehicle_plate' => 'PTC-999',
        'type' => 'Oil Change',
        'description' => 'Synced from GeoTab',
        'status' => 'recorded',
        'source' => 'geotab',
        'recorded_at' => now(),
        'odometer_km' => 13000,
    ]);
    $geotabRecordId = (string) MaintenanceHistory::query()->where('source', 'geotab')->first()->id;

    $this->patchJson('/api/fleet/maintenance/history/'.$geotabRecordId, [
        'type' => 'Battery',
    ])->assertStatus(423);

    $this->patchJson('/api/fleet/maintenance/history/'.$geotabRecordId, [
        'notes' => 'Local C3-04 supplement after paper review.',
        'proofFileName' => 'supplement.png',
        'proofFileType' => 'image/png',
        'proofDataUrl' => 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
    ])
        ->assertOk()
        ->assertJsonPath('data.notes', 'Local C3-04 supplement after paper review.')
        ->assertJsonPath('data.hasProof', true);

    $this->patchJson('/api/fleet/maintenance/history/'.$historyId, [
        'voidReason' => 'Duplicate record entered during testing.',
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'voided')
        ->assertJsonPath('data.voided', true)
        ->assertJsonPath('data.voidReason', 'Duplicate record entered during testing.');
});

test('manual driver crud preserves full profile fields for frontend forms', function () {
    $create = $this->postJson('/api/fleet/drivers/manual', [
        'name' => 'Full CRUD Driver',
        'license' => 'N04-12-345678',
        'phone' => '+63 917 123 4567',
        'email' => 'driver@example.test',
        'status' => 'available',
        'assignedVehicleGeotabId' => 'device-crud',
        'assignedVehiclePlate' => 'PTC-102',
        'meta' => [
            'licenseExpiry' => now()->addDays(20)->toDateString(),
            'address' => 'Cabuyao, Laguna',
            'emergencyContact' => 'Maria Cruz +63 917 000 1111',
        ],
    ])
        ->assertOk()
        ->assertJsonPath('data.name', 'Full CRUD Driver')
        ->assertJsonPath('data.license', 'N04-12-345678')
        ->assertJsonPath('data.licenseExpiry', now()->addDays(20)->toDateString())
        ->assertJsonPath('data.address', 'Cabuyao, Laguna')
        ->assertJsonPath('data.assignedVehicle', 'PTC-102')
        ->assertJsonPath('data.emergencyContact', 'Maria Cruz +63 917 000 1111');

    $driverId = $create->json('data.id');

    $this->patchJson('/api/fleet/drivers/manual/'.$driverId, [
        'name' => 'Edited CRUD Driver',
        'status' => 'inactive',
        'assignedVehiclePlate' => 'PTC-103',
        'meta' => [
            'licenseExpiry' => now()->addDays(10)->toDateString(),
            'address' => 'San Pedro, Laguna',
            'emergencyContact' => 'Pedro Cruz +63 917 222 3333',
        ],
    ])
        ->assertOk()
        ->assertJsonPath('data.name', 'Edited CRUD Driver')
        ->assertJsonPath('data.status', 'inactive')
        ->assertJsonPath('data.licenseExpiry', now()->addDays(10)->toDateString())
        ->assertJsonPath('data.address', 'San Pedro, Laguna')
        ->assertJsonPath('data.assignedVehicle', 'PTC-103')
        ->assertJsonPath('data.emergencyContact', 'Pedro Cruz +63 917 222 3333');

    $this->patchJson('/api/fleet/drivers/manual/'.$driverId, [
        'status' => 'available',
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'available');

    $this->deleteJson('/api/fleet/drivers/manual/'.$driverId.'/permanent')
        ->assertOk()
        ->assertJsonPath('data.deleted', true);

    expect(ManualDriver::query()->find($driverId))->toBeNull();
});

test('billing invoices expose policy intelligence and pod collection readiness', function () {
    Cache::flush();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-BILLING-POLICY',
        'customer' => 'Policy Client',
        'origin' => 'Pioneer Office',
        'destination' => 'AP Cargo Forwarder',
        'amount' => 15000,
        'status' => 'completed',
        'notes' => 'Created from dispatch workflow. AP Cargo client pass-through.',
    ])->assertOk();

    $response = $this->getJson('/api/billing/invoices')
        ->assertOk()
        ->assertJsonPath('success', true);

    expect((int) $response->json('data.overview.manualReviewCount'))->toBeGreaterThanOrEqual(1)
        ->and((int) $response->json('data.overview.thirdPartyCandidateCount'))->toBeGreaterThanOrEqual(1)
        ->and($response->json('data.overview'))->toHaveKeys([
            'totalInvoicedThisMonth',
            'totalCollectedThisMonth',
            'outstandingBalance',
            'overdueAmount',
        ]);

    $invoice = collect($response->json('data.invoices'))
        ->firstWhere('tripId', 'TRP-BILLING-POLICY');

    expect($invoice)->not->toBeNull()
        ->and($invoice['manualReviewRequired'])->toBeTrue()
        ->and($invoice['thirdPartyCandidate'])->toBeTrue()
        ->and($invoice['podReady'])->toBeFalse()
        ->and($invoice['collectionReadiness'])->toBe('Hold for POD')
        ->and($invoice['pricingModel'])->toBe('Third-party pass-through review')
        ->and($invoice['pricingRules'])->toHaveCount(3);
});

test('billing invoices expose delivery context vat breakdown and optional erp references', function () {
    Cache::flush();

    SystemSetting::query()->create([
        'vat_rate_percent' => 12,
    ]);

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-ERP-REF',
        'customer' => 'ERP Linked Client',
        'origin' => 'Pioneer Warehouse',
        'destination' => 'Client Warehouse',
        'amount' => 10000,
        'status' => 'completed',
    ])->assertOk();

    $this->putJson('/api/billing/invoices/TRP-ERP-REF/references', [
        'invoiceNumber' => 'INV-ERP-REF',
        'erpReference' => 'SO-2026-0001',
        'poNumber' => 'PO-CLIENT-123',
        'drNumber' => 'DR-9001',
        'notes' => 'Matched against ERP billing record.',
    ])
        ->assertOk()
        ->assertJsonPath('data.erpReference', 'SO-2026-0001')
        ->assertJsonPath('data.poNumber', 'PO-CLIENT-123')
        ->assertJsonPath('data.drNumber', 'DR-9001');

    $response = $this->getJson('/api/billing/invoices')
        ->assertOk()
        ->assertJsonPath('data.context.title', 'Delivery Trip Billing')
        ->assertJsonPath('data.context.vatRatePercent', 12);

    $invoice = collect($response->json('data.invoices'))
        ->firstWhere('tripId', 'TRP-ERP-REF');

    expect($invoice)->not->toBeNull()
        ->and($invoice['erpReference'])->toBe('SO-2026-0001')
        ->and($invoice['poNumber'])->toBe('PO-CLIENT-123')
        ->and($invoice['drNumber'])->toBe('DR-9001')
        ->and((float) $invoice['vatRatePercent'])->toBe(12.0)
        ->and($invoice)->toHaveKeys(['subtotalBeforeVat', 'vat', 'vatAmount', 'totalWithVat']);

    expect(BillingInvoiceReference::query()->where('trip_id', 'TRP-ERP-REF')->exists())->toBeTrue();
});

test('billing invoice list filters by status client trip date and pod readiness', function () {
    Cache::flush();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-FILTER-READY',
        'customer' => 'Filter Ready Client',
        'origin' => 'Pioneer Warehouse',
        'destination' => 'Client Dock',
        'amount' => 8000,
        'status' => 'completed',
    ])->assertOk();
    $this->postJson('/api/fleet/pod/TRP-FILTER-READY', billingVerifiedPodPayload())->assertOk();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-FILTER-HOLD',
        'customer' => 'Filter Hold Client',
        'origin' => 'Pioneer Warehouse',
        'destination' => 'Client Dock',
        'amount' => 6000,
        'status' => 'completed',
    ])->assertOk();

    $issued = collect($this->getJson('/api/billing/invoices?status=issued')
        ->assertOk()
        ->json('data.invoices'));
    expect($issued->pluck('tripId')->all())->toContain('TRP-FILTER-READY')
        ->not->toContain('TRP-FILTER-HOLD');

    $client = collect($this->getJson('/api/billing/invoices?client=Ready')
        ->assertOk()
        ->json('data.invoices'));
    expect($client->pluck('tripId')->all())->toContain('TRP-FILTER-READY');

    $trip = collect($this->getJson('/api/billing/invoices?tripId=FILTER-HOLD')
        ->assertOk()
        ->json('data.invoices'));
    expect($trip->pluck('tripId')->all())->toContain('TRP-FILTER-HOLD');

    $dated = collect($this->getJson('/api/billing/invoices?dateFrom='.now()->subDay()->toDateString().'&dateTo='.now()->addDay()->toDateString())
        ->assertOk()
        ->json('data.invoices'));
    expect($dated->pluck('tripId')->all())->toContain('TRP-FILTER-READY')
        ->toContain('TRP-FILTER-HOLD');

    $ready = collect($this->getJson('/api/billing/invoices?podReady=ready')
        ->assertOk()
        ->json('data.invoices'));
    expect($ready->pluck('tripId')->all())->toContain('TRP-FILTER-READY')
        ->not->toContain('TRP-FILTER-HOLD');

    $hold = collect($this->getJson('/api/billing/invoices?podReady=hold')
        ->assertOk()
        ->json('data.invoices'));
    expect($hold->pluck('tripId')->all())->toContain('TRP-FILTER-HOLD');
});

test('manual invoice creation requires a linked trip and stores override audit state', function () {
    Cache::flush();

    $this->postJson('/api/billing/invoices', [
        'overrideReason' => 'Emergency accounting correction.',
    ])->assertUnprocessable();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-MANUAL-INVOICE',
        'customer' => 'Manual Invoice Client',
        'origin' => 'Pioneer Warehouse',
        'destination' => 'Client Site',
        'amount' => 12000,
        'status' => 'completed',
    ])->assertOk();

    $response = $this->postJson('/api/billing/invoices', [
        'tripId' => 'TRP-MANUAL-INVOICE',
        'status' => 'draft',
        'overrideReason' => 'Client-approved billing adjustment.',
        'lineItems' => [
            ['label' => 'Base delivery charge', 'amount' => 8000],
            ['label' => 'Fuel cost estimate', 'amount' => 1400],
        ],
        'poNumber' => 'PO-MANUAL-1',
    ])
        ->assertOk()
        ->assertJsonPath('data.tripId', 'TRP-MANUAL-INVOICE')
        ->assertJsonPath('data.status', 'draft')
        ->assertJsonPath('data.manualInvoice', true)
        ->assertJsonPath('data.poNumber', 'PO-MANUAL-1');

    expect($response->json('data.overrideReason'))->toBe('Client-approved billing adjustment.')
        ->and($response->json('data.itemizedBreakdown'))->toHaveCount(2)
        ->and(BillingInvoiceReference::query()->where('trip_id', 'TRP-MANUAL-INVOICE')->where('manual_invoice', true)->exists())->toBeTrue();
});

test('rejected billing invoices store the rejection reason and audit trail', function () {
    Cache::flush();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-INVOICE-REJECT',
        'customer' => 'Rejected Invoice Client',
        'origin' => 'Warehouse',
        'destination' => 'Customer',
        'amount' => 5000,
        'status' => 'completed',
    ])->assertOk();

    $this->postJson('/api/billing/invoices', [
        'tripId' => 'TRP-INVOICE-REJECT',
        'status' => 'rejected',
        'overrideReason' => 'Manual hold for missing POD.',
        'rejectionReason' => 'POD photo and delivery signature are still missing.',
        'lineItems' => [
            ['label' => 'Delivery charge', 'amount' => 5000],
        ],
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'rejected')
        ->assertJsonPath('data.rejectionReason', 'POD photo and delivery signature are still missing.');

    $reference = BillingInvoiceReference::query()
        ->where('trip_id', 'TRP-INVOICE-REJECT')
        ->firstOrFail();

    expect($reference->status)->toBe('rejected')
        ->and($reference->meta['rejectionReason'])->toBe('POD photo and delivery signature are still missing.')
        ->and($reference->status_history)->toHaveCount(1);
});

test('invoice status transitions references paid lock and voiding rules are enforced', function () {
    Cache::flush();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-INVOICE-LIFE',
        'customer' => 'Lifecycle Client',
        'origin' => 'Warehouse',
        'destination' => 'Customer',
        'amount' => 9000,
        'status' => 'completed',
    ])->assertOk();

    $this->postJson('/api/billing/invoices', [
        'tripId' => 'TRP-INVOICE-LIFE',
        'status' => 'draft',
        'overrideReason' => 'Manual draft for accounting review.',
        'lineItems' => [
            ['label' => 'Delivery charge', 'amount' => 9000],
        ],
    ])->assertOk();

    $this->patchJson('/api/billing/invoices/TRP-INVOICE-LIFE', [
        'status' => 'approved',
        'approvalNote' => 'Cannot approve without POD.',
    ])->assertStatus(422);

    $this->postJson('/api/fleet/pod/TRP-INVOICE-LIFE', billingVerifiedPodPayload())
        ->assertOk()
        ->assertJsonPath('data.status', 'delivered');

    $this->patchJson('/api/billing/invoices/TRP-INVOICE-LIFE', [
        'status' => 'approved',
        'approvalNote' => 'GPS and POD evidence reviewed.',
    ])->assertOk()
        ->assertJsonPath('data.status', 'approved')
        ->assertJsonPath('data.approvalNote', 'GPS and POD evidence reviewed.');

    $this->patchJson('/api/billing/invoices/TRP-INVOICE-LIFE', [
        'status' => 'issued',
        'finalChargeBasis' => 'Final charge uses completed trip distance and signed POD.',
    ])->assertOk()
        ->assertJsonPath('data.status', 'issued')
        ->assertJsonPath('data.finalChargeBasis', 'Final charge uses completed trip distance and signed POD.');

    $this->patchJson('/api/billing/invoices/TRP-INVOICE-LIFE', [
        'status' => 'paid',
        'paymentReference' => 'OR-2026-0007',
        'paymentDate' => '2026-06-02',
    ])->assertOk()
        ->assertJsonPath('data.status', 'paid')
        ->assertJsonPath('data.paymentReference', 'OR-2026-0007');

    $this->patchJson('/api/billing/invoices/TRP-INVOICE-LIFE', [
        'lineItems' => [
            ['label' => 'Changed charge', 'amount' => 1],
        ],
        'overrideReason' => 'Should be blocked.',
    ])->assertStatus(423);

    $this->putJson('/api/billing/invoices/TRP-INVOICE-LIFE/references', [
        'poNumber' => 'PO-PAID-OK',
        'drNumber' => 'DR-PAID-OK',
    ])->assertOk()->assertJsonPath('data.poNumber', 'PO-PAID-OK');

    $this->postJson('/api/billing/invoices/TRP-INVOICE-LIFE/void', [
        'reason' => 'Cannot void paid invoice.',
    ])->assertStatus(423);

    $history = BillingInvoiceReference::query()
        ->where('trip_id', 'TRP-INVOICE-LIFE')
        ->firstOrFail()
        ->status_history;

    expect($history)->toHaveCount(4);
});

test('issued invoices can be voided and remain visible in statement of accounts', function () {
    Cache::flush();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-INVOICE-VOID',
        'customer' => 'Voided Client',
        'origin' => 'Warehouse',
        'destination' => 'Customer',
        'amount' => 7000,
        'status' => 'completed',
    ])->assertOk();

    $this->postJson('/api/fleet/pod/TRP-INVOICE-VOID', billingVerifiedPodPayload())->assertOk();

    $this->patchJson('/api/billing/invoices/TRP-INVOICE-VOID', [
        'status' => 'approved',
        'approvalNote' => 'Ready for invoice issue.',
    ])->assertOk()->assertJsonPath('data.status', 'approved');

    $this->patchJson('/api/billing/invoices/TRP-INVOICE-VOID', [
        'status' => 'issued',
        'finalChargeBasis' => 'Completed trip with verified POD.',
    ])->assertOk()->assertJsonPath('data.status', 'issued');

    $this->patchJson('/api/billing/invoices/TRP-INVOICE-VOID', [
        'status' => 'overdue',
    ])->assertOk()->assertJsonPath('data.status', 'overdue');

    $this->postJson('/api/billing/invoices/TRP-INVOICE-VOID/void', [
        'reason' => 'Duplicate ERP billing reference.',
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'voided')
        ->assertJsonPath('data.voidReason', 'Duplicate ERP billing reference.');

    $soa = $this->getJson('/api/billing/soa')
        ->assertOk()
        ->json('data.clients');

    $client = collect($soa)->firstWhere('name', 'Voided Client');
    expect($client)->not->toBeNull();
    $row = collect($client['invoiceRows'])->firstWhere('tripId', 'TRP-INVOICE-VOID');
    expect($row['status'])->toBe('voided')
        ->and($row['voidReason'])->toBe('Duplicate ERP billing reference.')
        ->and((float) $client['outstanding'])->toBe(0.0);
});

test('vehicle subscription coverage report groups active plates by client for erp copy paste', function () {
    ClientVehicleAssignment::query()->create([
        'client_name' => 'Empire Oil',
        'vehicle_plate' => 'ZRX 294',
        'status' => 'active',
    ]);
    ClientVehicleAssignment::query()->create([
        'client_name' => 'Empire Oil',
        'vehicle_plate' => 'NBC 8416',
        'status' => 'active',
    ]);

    $response = $this->getJson('/api/fleet/reports/vehicle-subscription-coverage')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.title', 'Vehicle Subscription Coverage')
        ->assertJsonPath('data.groups.0.client', 'Empire Oil');

    expect($response->json('data.groups.0.copyText'))->toBe('1. NBC 8416 2. ZRX 294');
    expect((int) $response->json('data.totalClients'))->toBeGreaterThanOrEqual(1)
        ->and((int) $response->json('data.totalVehicles'))->toBeGreaterThanOrEqual(2);
});

test('custom trips expose sales to delivery workflow state', function () {
    Cache::flush();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-WORKFLOW',
        'customer' => 'Workflow Client',
        'origin' => 'Cabuyao Warehouse',
        'destination' => 'Client Site',
        'amount' => 2500,
        'orderValue' => 125000,
        'totalWeightKg' => 780,
        'poReceived' => true,
        'salesChannel' => 'Viber',
        'status' => 'pending',
    ])->assertOk()
        ->assertJsonPath('data.fulfillmentMethod', 'free_delivery')
        ->assertJsonPath('data.fulfillmentLabel', 'Free delivery')
        ->assertJsonPath('data.workflowPhase', 'sales')
        ->assertJsonPath('data.workflowPhaseLabel', 'Inquiry & quotation')
        ->assertJsonPath('data.workflowPhaseNumber', 1)
        ->assertJsonPath('data.workflowGroup', 'Pending Assignment')
        ->assertJsonPath('data.clientWorkflowStatus', 'Your order is being prepared')
        ->assertJsonPath('data.workflowSteps.0.label', 'Inquiry received')
        ->assertJsonPath('data.workflowSteps.5.owner', 'Service Advisor')
        ->assertJsonCount(12, 'data.workflowSteps');

    $this->patchJson('/api/fleet/trips/TRP-WORKFLOW', [
        'status' => 'dispatched',
        'vehicle' => 'TRK-001',
        'driver' => 'Driver One',
    ])->assertOk()
        ->assertJsonPath('data.workflowPhase', 'execution')
        ->assertJsonPath('data.workflowPhaseLabel', 'Delivery execution')
        ->assertJsonPath('data.workflowPhaseNumber', 11)
        ->assertJsonPath('data.workflowGroup', 'In Transit')
        ->assertJsonPath('data.clientWorkflowStatus', 'Your delivery has arrived')
        ->assertJsonCount(12, 'data.workflowSteps');
});

test('trip lifecycle crud supports full dispatch form fields and soft cancellation', function () {
    Cache::flush();

    $scheduled = now()->addDay()->setSecond(0)->toIso8601String();
    $estimated = now()->addDays(2)->setSecond(0)->toIso8601String();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-FULL-CRUD',
        'customer' => 'CRUD Client',
        'origin' => 'Pioneer Warehouse',
        'destination' => 'Client Receiving Dock',
        'cargoType' => 'Fragile',
        'totalWeightKg' => 820.5,
        'orderValue' => 125000,
        'amount' => 125000,
        'vehicle' => 'PTC-CRUD',
        'driver' => 'CRUD Driver',
        'scheduledDepartureAt' => $scheduled,
        'estimatedArrivalAt' => $estimated,
        'specialInstructions' => 'Call receiving guard before arrival.',
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'pending')
        ->assertJsonPath('data.workflowPhaseNumber', 1)
        ->assertJsonPath('data.cargoType', 'Fragile')
        ->assertJsonPath('data.totalWeightKg', 820.5)
        ->assertJsonPath('data.orderValue', 125000)
        ->assertJsonPath('data.freeDeliveryCandidate', true)
        ->assertJsonPath('data.scheduledDepartureAt', $scheduled)
        ->assertJsonPath('data.estimatedArrivalAt', $estimated)
        ->assertJsonPath('data.specialInstructions', 'Call receiving guard before arrival.');

    expect(FleetTrip::query()->where('trip_id', 'TRP-FULL-CRUD')->exists())->toBeTrue();
    Cache::forget('geotab_workflow_state_v1');
    $this->getJson('/api/fleet/trips/TRP-FULL-CRUD')
        ->assertOk()
        ->assertJsonPath('data.tripId', 'TRP-FULL-CRUD')
        ->assertJsonPath('data.status', 'pending');

    $this->patchJson('/api/fleet/trips/TRP-FULL-CRUD', [
        'cargoType' => 'Hazardous',
        'totalWeightKg' => 900,
        'orderValue' => 90000,
        'vehicle' => 'PTC-EDIT',
        'driver' => 'Edited Driver',
        'specialInstructions' => 'Updated handling note.',
    ])
        ->assertOk()
        ->assertJsonPath('data.cargoType', 'Hazardous')
        ->assertJsonPath('data.totalWeightKg', 900)
        ->assertJsonPath('data.orderValue', 90000)
        ->assertJsonPath('data.vehicle', 'PTC-EDIT')
        ->assertJsonPath('data.driver', 'Edited Driver')
        ->assertJsonPath('data.specialInstructions', 'Updated handling note.');

    $this->patchJson('/api/fleet/trips/TRP-FULL-CRUD', [
        'status' => 'cancelled',
        'cancellationReason' => 'Client postponed receiving schedule.',
        'cancelledAt' => now()->toIso8601String(),
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'cancelled')
        ->assertJsonPath('data.cancellationReason', 'Client postponed receiving schedule.')
        ->assertJsonPath('data.arrivalState', 'cancelled')
        ->assertJsonPath('data.arrivedAtDestination', false);
});

test('dispatch workflow phase can advance and stage relevant geotab writeback', function () {
    Cache::flush();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-PHASE',
        'customer' => 'Phase Client',
        'origin' => 'Warehouse',
        'destination' => 'Client',
        'amount' => 5000,
        'routeGeotabId' => 'route-phase',
        'deviceGeotabId' => 'device-phase',
    ])->assertOk();

    $this->patchJson('/api/fleet/trips/TRP-PHASE', [
        'workflowPhaseNumber' => 10,
        'status' => 'dispatched',
        'routeGeotabId' => 'route-phase',
        'deviceGeotabId' => 'device-phase',
    ])->assertOk()
        ->assertJsonPath('data.workflowPhaseNumber', 10)
        ->assertJsonPath('data.workflowGroup', 'In Transit')
        ->assertJsonPath('data.clientWorkflowStatus', 'Your delivery is on its way')
        ->assertJsonCount(12, 'data.workflowSteps');

    expect(GeotabWriteJob::query()
        ->where('action', 'route.assign_device')
        ->where('local_type', 'trip')
        ->where('local_id', 'TRP-PHASE')
        ->count())->toBe(1);
});

test('maintenance due notification is created once for due records', function () {
    Cache::flush();

    $response = $this->postJson('/api/fleet/maintenance/history', [
        'vehiclePlate' => 'TRK-DUE',
        'type' => 'Preventive Maintenance',
        'description' => 'Scheduled maintenance threshold reached.',
        'status' => 'recorded',
        'recordedAt' => now()->subDays(2)->toIso8601String(),
        'nextDueAt' => now()->subDay()->toIso8601String(),
        'odometerKm' => 88000,
    ])->assertOk();

    $historyId = $response->json('data.id');
    expect(NotificationHistory::query()
        ->where('notification_id', 'maintenance-due-'.$historyId)
        ->count())->toBe(1);

    $this->patchJson('/api/fleet/maintenance/history/'.$historyId, [
        'status' => 'overdue',
    ])->assertOk();

    expect(NotificationHistory::query()
        ->where('notification_id', 'maintenance-due-'.$historyId)
        ->count())->toBe(1);
});

test('humidity breach feed rows create idempotent operational notifications', function () {
    Cache::flush();

    GeotabFeedRow::query()->create([
        'type_name' => 'StatusData',
        'geotab_id' => 'status-humidity-1',
        'device_geotab_id' => 'device-humidity',
        'diagnostic_alias' => 'relativeHumidity',
        'feed_cursor' => 'cursor-1',
        'recorded_at' => now(),
        'payload_hash' => hash('sha256', 'humidity-breach-1'),
        'payload' => ['value' => 86],
    ]);

    $this->getJson('/api/fleet/dashboard/summary')->assertOk();
    $this->getJson('/api/fleet/dashboard/summary')->assertOk();

    expect(NotificationHistory::query()
        ->where('notification_id', 'humidity-breach-device-humidity-'.now()->format('Ymd'))
        ->count())->toBe(1);
});
