<?php

use App\Services\GeotabService;
use Carbon\CarbonInterface;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;

uses(RefreshDatabase::class);

beforeEach(function () {
    Cache::flush();
});

test('fleet routes include geotab route plan items as ordered planned stops', function () {
    app()->instance(GeotabService::class, new class extends GeotabService
    {
        public function isConfigured(): bool
        {
            return true;
        }

        public function getDevices(): array
        {
            return [];
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
            return [
                [
                    'id' => 'zone-origin',
                    'name' => 'Warehouse A',
                    'points' => [
                        ['x' => 120.9800, 'y' => 14.5900],
                        ['x' => 120.9820, 'y' => 14.5900],
                        ['x' => 120.9820, 'y' => 14.5920],
                        ['x' => 120.9800, 'y' => 14.5920],
                    ],
                ],
                [
                    'id' => 'zone-destination',
                    'name' => 'Customer B',
                    'points' => [
                        ['x' => 121.0100, 'y' => 14.6200],
                        ['x' => 121.0120, 'y' => 14.6200],
                        ['x' => 121.0120, 'y' => 14.6220],
                        ['x' => 121.0100, 'y' => 14.6220],
                    ],
                ],
            ];
        }

        public function getRoutes(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [[
                'id' => 'route-test',
                'name' => 'Test Route',
                'device' => null,
                'startTime' => null,
                'endTime' => null,
                'routePlanItemCollection' => [],
            ]];
        }

        public function getRoutePlanItems(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 500): array
        {
            return [
                [
                    'id' => 'plan-2',
                    'route' => ['id' => 'route-test'],
                    'zone' => ['id' => 'zone-destination'],
                    'sequence' => 2,
                    'dateTime' => '2026-05-02T10:30:00Z',
                ],
                [
                    'id' => 'plan-1',
                    'route' => ['id' => 'route-test'],
                    'zone' => ['id' => 'zone-origin'],
                    'sequence' => 1,
                    'dateTime' => '2026-05-02T09:00:00Z',
                ],
            ];
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
            return [];
        }

        public function getFuelAndEnergyUsed(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 250): array
        {
            return [];
        }

        public function getFuelTransactions(?CarbonInterface $from = null, ?CarbonInterface $to = null, int $limit = 500): array
        {
            return [];
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
    });

    $this->getJson('/api/fleet/routes')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.0.name', 'Test Route')
        ->assertJsonPath('data.0.deviceId', '')
        ->assertJsonPath('data.0.stopCount', 2)
        ->assertJsonPath('data.0.routeAvailable', true)
        ->assertJsonPath('data.0.stops.0.name', 'Warehouse A')
        ->assertJsonPath('data.0.stops.1.name', 'Customer B')
        ->assertJsonCount(2, 'data.0.plannedPath');

    $this->getJson('/api/fleet/trips')
        ->assertOk()
        ->assertJsonPath('success', true)
        ->assertJsonPath('data.0.status', 'pending')
        ->assertJsonPath('data.0.source', 'geotab_route_plan')
        ->assertJsonPath('data.0.isRoutePlan', true)
        ->assertJsonPath('data.0.customer', 'Test Route')
        ->assertJsonPath('data.0.origin', 'Warehouse A')
        ->assertJsonPath('data.0.destination', 'Customer B')
        ->assertJsonPath('data.0.routeName', 'Test Route')
        ->assertJsonCount(2, 'data.0.routedPlaces')
        ->assertJsonCount(2, 'data.0.plannedPath');
});
