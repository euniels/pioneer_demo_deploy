<?php

namespace Database\Seeders;

use App\Models\BillingInvoiceReference;
use App\Models\FleetClient;
use App\Models\FleetRoute;
use App\Models\FleetRouteStop;
use App\Models\FleetTrip;   
use App\Models\GpsLog;
use App\Models\MaintenanceHistory;
use App\Models\ManualDriver;
use App\Models\ManualVehicle;
use App\Models\NotificationHistory;
use App\Models\ProofOfDelivery;
use App\Models\User;
use Illuminate\Database\Seeder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Schema;

class PioneerDemoFlowSeeder extends Seeder
{
    public function run(): void
    {
        if (app()->environment('production') && ! (bool) config('pioneer.show_mock_data', false)) {
            $this->command?->error('Demo data seeding is disabled in production.');

            return;
        }

        DB::transaction(function (): void {
            $this->seedUsers();
            $clients = $this->seedClients();
            $vehicles = $this->seedVehicles();
            $drivers = $this->seedDrivers($vehicles);
            $route = $this->seedRoute($vehicles[0]);
            $this->seedTrips($clients, $vehicles, $drivers, $route);
            $this->seedMaintenance($vehicles);
            $this->seedNotifications();
        });

        $this->command?->info('PioneerPath demo flow data is ready.');
    }

    private function seedUsers(): void
    {
        if (! Schema::hasTable('users')) {
            return;
        }

        foreach ([
            ['Demo Fleet Manager', 'demo.fleet@pioneerpath.local', 'fleet_manager'],
            ['Demo Dispatcher', 'demo.dispatch@pioneerpath.local', 'dispatcher'],
            ['Demo Accounting Staff', 'demo.accounting@pioneerpath.local', 'accounting_staff'],
        ] as [$name, $email, $role]) {
            User::query()->updateOrCreate(
                ['email' => $email],
                [
                    'name' => $name,
                    'password' => Hash::make('Pioneer@12345'),
                    'role' => $role,
                    'status' => 'active',
                    'must_change_password' => false,
                    'activity_log' => [
                        [
                            'timestamp' => now()->toIso8601String(),
                            'action' => 'demo_seeded',
                            'description' => 'Demo account prepared for client walkthrough.',
                        ],
                    ],
                ],
            );
        }
    }

    /**
     * @return array<int, FleetClient>
     */
    private function seedClients(): array
    {
        if (! Schema::hasTable('fleet_clients')) {
            return [];
        }

        $records = [
            [
                'company_name' => 'Demo Client - North Distribution',
                'contact_person_name' => 'Maria Santos',
                'contact_number' => '+63 917 555 0101',
                'email' => 'north.demo@example.com',
                'billing_address' => 'Mandaluyong City, Metro Manila',
                'delivery_address' => 'Warehouse 4, Caloocan City',
                'client_type' => 'regular',
                'payment_terms' => '30_days_net',
                'free_delivery_threshold' => 100000,
                'erp_customer_id' => 'DEMO-CUST-001',
            ],
            [
                'company_name' => 'Demo Client - Cold Chain Retail',
                'contact_person_name' => 'Jose Reyes',
                'contact_number' => '+63 917 555 0102',
                'email' => 'coldchain.demo@example.com',
                'billing_address' => 'Pasig City, Metro Manila',
                'delivery_address' => 'Retail Hub, Quezon City',
                'client_type' => 'priority',
                'payment_terms' => 'cod',
                'free_delivery_threshold' => 75000,
                'erp_customer_id' => 'DEMO-CUST-002',
            ],
        ];

        return array_map(
            fn (array $record): FleetClient => FleetClient::query()->updateOrCreate(
                ['company_name' => $record['company_name']],
                [
                    ...$record,
                    'status' => 'active',
                    'audit_trail' => [
                        [
                            'timestamp' => now()->toIso8601String(),
                            'actor' => 'demo seeder',
                            'action' => 'created',
                        ],
                    ],
                    'meta' => ['demo_data' => true],
                ],
            ),
            $records,
        );
    }

    /**
     * @return array<int, ManualVehicle>
     */
    private function seedVehicles(): array
    {
        if (! Schema::hasTable('manual_vehicles')) {
            return [];
        }

        $records = [
            ['DEMO-TRK-01', 'Refrigerated Truck', 'Isuzu Forward Ref Van', 2023, 'Diesel', 80, 4200, 'demo-device-001', 'active'],
            ['DEMO-TRK-02', 'Closed Van', 'Mitsubishi Fuso Canter', 2022, 'Diesel', 70, 3500, 'demo-device-002', 'active'],
            ['DEMO-TRK-03', 'Wing Van', 'Hino 500 Wing Van', 2021, 'Diesel', 90, 6500, 'demo-device-003', 'maintenance'],
        ];

        return array_map(function (array $record): ManualVehicle {
            [$plate, $type, $model, $year, $fuel, $fuelCapacity, $cargoCapacity, $deviceId, $status] = $record;

            return ManualVehicle::query()->updateOrCreate(
                ['plate_number' => $plate],
                [
                    'vehicle_type' => $type,
                    'make_model' => $model,
                    'year' => $year,
                    'vin' => 'DEMO-VIN-'.$plate,
                    'fuel_type' => $fuel,
                    'fuel_capacity_liters' => $fuelCapacity,
                    'cargo_capacity_kg' => $cargoCapacity,
                    'geotab_device_id' => $deviceId,
                    'registration_expiry_date' => now()->addMonths(10)->toDateString(),
                    'insurance_expiry_date' => now()->addMonths(8)->toDateString(),
                    'status' => $status,
                    'sync_status' => 'not_staged',
                    'meta' => ['demo_data' => true],
                ],
            );
        }, $records);
    }

    /**
     * @param  array<int, ManualVehicle>  $vehicles
     * @return array<int, ManualDriver>
     */
    private function seedDrivers(array $vehicles): array
    {
        if (! Schema::hasTable('manual_drivers')) {
            return [];
        }

        $records = [
            ['Demo Driver Juan Dela Cruz', 'N01-22-123456', '+63 917 555 0201', 'juan.demo@example.com', 'on_trip', $vehicles[0] ?? null],
            ['Demo Driver Ana Lopez', 'N02-23-654321', '+63 917 555 0202', 'ana.demo@example.com', 'available', $vehicles[1] ?? null],
            ['Demo Driver Mark Lim', 'N03-21-456789', '+63 917 555 0203', 'mark.demo@example.com', 'available', null],
        ];

        return array_map(function (array $record): ManualDriver {
            [$name, $license, $phone, $email, $status, $vehicle] = $record;
            $user = null;
            if (Schema::hasTable('users')) {
                $user = User::query()->updateOrCreate(
                    ['email' => $email],
                    [
                        'name' => $name,
                        'password' => Hash::make('Pioneer@12345'),
                        'role' => 'driver',
                        'phone' => $phone,
                        'status' => in_array($status, ['inactive', 'deactivated'], true) ? 'inactive' : 'active',
                        'must_change_password' => false,
                        'created_by' => 'demo seeder',
                        'activity_log' => [
                            [
                                'timestamp' => now()->toIso8601String(),
                                'action' => 'demo_seeded_driver_account',
                                'description' => 'Linked demo driver portal account prepared for client walkthrough.',
                            ],
                        ],
                    ],
                );
            }

            return ManualDriver::query()->updateOrCreate(
                ['email' => $email],
                [
                    ...(Schema::hasColumn('manual_drivers', 'user_id') ? ['user_id' => $user?->id] : []),
                    'name' => $name,
                    'license' => $license,
                    'phone' => $phone,
                    'status' => $status,
                    'base_salary' => 25000,
                    'per_trip_bonus' => 500,
                    'assigned_vehicle_geotab_id' => $vehicle?->geotab_device_id,
                    'assigned_vehicle_plate' => $vehicle?->plate_number,
                    'sync_status' => 'not_staged',
                    'meta' => ['demo_data' => true],
                ],
            );
        }, $records);
    }

    private function seedRoute(?ManualVehicle $vehicle): ?FleetRoute
    {
        if (! Schema::hasTable('fleet_routes')) {
            return null;
        }

        $route = FleetRoute::query()->updateOrCreate(
            ['name' => 'Demo Route - Metro Manila Northbound'],
            [
                'description' => 'Client demo route from depot to distribution destinations.',
                'assigned_vehicle_geotab_id' => $vehicle?->geotab_device_id,
                'assigned_vehicle_plate' => $vehicle?->plate_number,
                'status' => 'active',
                'sync_status' => 'not_staged',
                'last_used_at' => now()->subHours(2),
                'meta' => ['demo_data' => true],
            ],
        );

        if (Schema::hasTable('fleet_route_stops')) {
            $route->stops()->delete();
            foreach ([
                [1, 'Demo Depot - Mandaluyong', 14.5794, 121.0359, 15],
                [2, 'Demo Stop - Quezon City Hub', 14.6760, 121.0437, 25],
                [3, 'Demo Destination - Caloocan Warehouse', 14.6507, 120.9676, 35],
            ] as [$sequence, $name, $lat, $lng, $duration]) {
                FleetRouteStop::query()->create([
                    'fleet_route_id' => $route->id,
                    'stop_sequence' => $sequence,
                    'stop_name' => $name,
                    'geotab_zone_id' => 'demo-zone-'.$sequence,
                    'latitude' => $lat,
                    'longitude' => $lng,
                    'estimated_stop_duration_minutes' => $duration,
                    'meta' => ['demo_data' => true],
                ]);
            }
        }

        return $route;
    }

    /**
     * @param  array<int, FleetClient>  $clients
     * @param  array<int, ManualVehicle>  $vehicles
     * @param  array<int, ManualDriver>  $drivers
     */
    private function seedTrips(array $clients, array $vehicles, array $drivers, ?FleetRoute $route): void
    {
        if (! Schema::hasTable('fleet_trips')) {
            return;
        }

        $now = now();
        $tripRows = [
            ['DEMO-TRIP-REQUEST', 'pending', 2, $clients[0] ?? null, null, null, $now->addHours(6), 0, false],
            ['DEMO-TRIP-ASSIGNED', 'assigned', 6, $clients[0] ?? null, $vehicles[1] ?? null, $drivers[1] ?? null, $now->addHours(3), 18500, false],
            ['DEMO-TRIP-LIVE', 'in_progress', 7, $clients[1] ?? null, $vehicles[0] ?? null, $drivers[0] ?? null, $now->subHour(), 24500, false],
            ['DEMO-TRIP-POD-HOLD', 'completed', 10, $clients[1] ?? null, $vehicles[1] ?? null, $drivers[1] ?? null, $now->subDay(), 21750, false],
            ['DEMO-TRIP-BILLED', 'completed', 12, $clients[0] ?? null, $vehicles[0] ?? null, $drivers[0] ?? null, $now->subDays(2), 32000, true],
        ];

        foreach ($tripRows as [$tripId, $status, $phase, $client, $vehicle, $driver, $scheduledAt, $amount, $withBilling]) {
            $payload = $this->tripPayload(
                $tripId,
                $status,
                $phase,
                $client,
                $vehicle,
                $driver,
                Carbon::parse($scheduledAt),
                (float) $amount,
                $route,
            );

            FleetTrip::query()->updateOrCreate(
                ['trip_id' => $tripId],
                [
                    'status' => $status,
                    'workflow_phase_number' => $phase,
                    'customer' => (string) ($payload['customer'] ?? 'Demo Client'),
                    'driver' => trim((string) ($payload['driver'] ?? '')) ?: null,
                    'vehicle' => trim((string) ($payload['vehicle'] ?? '')) ?: null,
                    'scheduled_departure_at' => $scheduledAt,
                    'payload' => $payload,
                ],
            );

            $this->seedGpsLogs($tripId, (string) ($vehicle?->geotab_device_id ?? 'demo-device-001'));

            if ($phase >= 10) {
                $this->seedProofOfDelivery($tripId, $phase >= 11);
            }

            if ($withBilling) {
                $this->seedBillingReference($tripId);
            }
        }
    }

    private function tripPayload(
        string $tripId,
        string $status,
        int $phase,
        ?FleetClient $client,
        ?ManualVehicle $vehicle,
        ?ManualDriver $driver,
        Carbon $scheduledAt,
        float $amount,
        ?FleetRoute $route,
    ): array {
        $origin = 'Demo Depot - Mandaluyong';
        $destination = str_contains($tripId, 'BILLED')
            ? 'Demo Destination - Caloocan Warehouse'
            : 'Demo Stop - Quezon City Hub';

        return [
            'tripId' => $tripId,
            'customer' => $client?->company_name ?? 'Demo Client',
            'phone' => $client?->contact_number ?? 'N/A',
            'origin' => $origin,
            'destination' => $destination,
            'cargoType' => str_contains($tripId, 'LIVE') ? 'Temperature-sensitive cargo' : 'General delivery',
            'vehicle' => $vehicle?->plate_number ?? '',
            'driver' => $driver?->name ?? '',
            'driverId' => $driver !== null ? 'manual-'.$driver->id : '',
            'assignedDriverId' => $driver !== null ? 'manual-'.$driver->id : '',
            'status' => $status,
            'amount' => $amount,
            'orderValue' => $amount,
            'distanceKm' => $amount > 0 ? 42.5 : 0,
            'totalWeightKg' => $amount > 0 ? 1200 : null,
            'scheduledDepartureAt' => $scheduledAt->toIso8601String(),
            'estimatedArrivalAt' => $scheduledAt->copy()->addHours(3)->toIso8601String(),
            'specialInstructions' => 'Demo flow for client walkthrough.',
            'freeDeliveryCandidate' => false,
            'freeDeliveryThreshold' => $client?->free_delivery_threshold ?? 100000,
            'fulfillmentMethod' => 'Pioneer delivery',
            'salesChannel' => 'Demo',
            'quotationStatus' => 'not_applicable',
            'poReceived' => $phase >= 6,
            'notes' => 'Seeded demo delivery trip.',
            'date' => $scheduledAt->format('M d, Y'),
            'sortAt' => $scheduledAt->toIso8601String(),
            'workflowPhaseNumber' => $phase,
            'workflowPhaseLocked' => true,
            'startedAt' => $phase >= 7 ? $scheduledAt->toIso8601String() : null,
            'endedAt' => $status === 'completed' ? $scheduledAt->copy()->addHours(3)->toIso8601String() : null,
            'routeName' => $route?->name,
            'routeGeotabId' => $route?->geotab_route_id,
            'deviceGeotabId' => $vehicle?->geotab_device_id,
            'routedPlaces' => [],
            'currentZone' => $phase >= 8 ? $destination : $origin,
            'originZone' => $origin,
            'destinationZone' => $destination,
            'arrivalState' => $phase >= 8 ? 'arrived' : 'pending',
            'arrivedAtDestination' => $phase >= 8,
            'startPoint' => ['latitude' => 14.5794, 'longitude' => 121.0359],
            'stopPoint' => ['latitude' => 14.6507, 'longitude' => 120.9676],
            'meta' => ['demo_data' => true],
        ];
    }

    private function seedGpsLogs(string $tripId, string $deviceId): void
    {
        if (! Schema::hasTable('gps_logs')) {
            return;
        }

        foreach ([
            [14.5794, 121.0359, 0, 0],
            [14.6112, 121.0202, 38, 25],
            [14.6507, 120.9676, 18, 50],
        ] as $index => [$lat, $lng, $speed, $minutes]) {
            GpsLog::query()->updateOrCreate(
                ['geotab_log_id' => $tripId.'-demo-log-'.$index],
                [
                    'trip_id' => $tripId,
                    'device_geotab_id' => $deviceId,
                    'latitude' => $lat,
                    'longitude' => $lng,
                    'speed' => $speed,
                    'bearing' => 30,
                    'recorded_at' => now()->subMinutes(60 - $minutes),
                    'association_status' => 'matched',
                    'meta' => ['demo_data' => true],
                ],
            );
        }
    }

    private function seedProofOfDelivery(string $tripId, bool $verified): void
    {
        if (! Schema::hasTable('proof_of_deliveries')) {
            return;
        }

        ProofOfDelivery::query()->updateOrCreate(
            ['trip_id' => $tripId],
            [
                'tracking_token' => 'demo-token-'.strtolower($tripId),
                'recipient_name' => $verified ? 'Demo Receiver' : null,
                'notes' => $verified ? 'Demo POD verified by accounting.' : 'Demo POD submitted and waiting for verification.',
                'signature_data_url' => null,
                'status' => $verified ? 'verified' : 'submitted',
                'delivered_at' => now()->subHours($verified ? 28 : 4),
                'attachments' => [
                    ['name' => 'demo-pod-photo.jpg', 'type' => 'image/jpeg', 'demo' => true],
                ],
                'meta' => ['demo_data' => true],
            ],
        );
    }

    private function seedBillingReference(string $tripId): void
    {
        if (! Schema::hasTable('billing_invoice_references')) {
            return;
        }

        BillingInvoiceReference::query()->updateOrCreate(
            ['trip_id' => $tripId],
            [
                'invoice_number' => 'INV-DEMO-001',
                'erp_reference' => 'SO-DEMO-001',
                'po_number' => 'PO-DEMO-001',
                'dr_number' => 'DR-DEMO-001',
                'notes' => 'Demo invoice linked to verified POD.',
                'status' => 'issued',
                'manual_invoice' => false,
                'override_reason' => null,
                'line_items' => [
                    ['label' => 'Base delivery charge', 'amount' => 12000],
                    ['label' => 'Distance/GPS charge', 'amount' => 14500],
                    ['label' => 'Fuel surcharge', 'amount' => 5500],
                ],
                'overrides' => [],
                'status_history' => [
                    ['timestamp' => now()->subHours(27)->toIso8601String(), 'status' => 'draft', 'note' => 'Demo invoice drafted from completed trip.'],
                    ['timestamp' => now()->subHours(26)->toIso8601String(), 'status' => 'approved', 'note' => 'Demo invoice approved after POD review.'],
                    ['timestamp' => now()->subHours(25)->toIso8601String(), 'status' => 'issued', 'note' => 'Demo invoice issued for SOA review.'],
                ],
                'meta' => [
                    'demo_data' => true,
                    'approvalNote' => 'POD and GPS evidence verified.',
                    'finalChargeBasis' => 'GPS distance, delivery charge, and fuel surcharge.',
                ],
            ],
        );
    }

    /**
     * @param  array<int, ManualVehicle>  $vehicles
     */
    private function seedMaintenance(array $vehicles): void
    {
        if (! Schema::hasTable('maintenance_histories')) {
            return;
        }

        foreach ($vehicles as $vehicle) {
            MaintenanceHistory::query()->updateOrCreate(
                [
                    'vehicle_plate' => $vehicle->plate_number,
                    'type' => 'Preventive Maintenance',
                    'recorded_at' => now()->subDays(10)->startOfDay(),
                ],
                [
                    'vehicle_geotab_id' => $vehicle->geotab_device_id,
                    'description' => 'Demo preventive maintenance check.',
                    'status' => $vehicle->status === 'maintenance' ? 'in_progress' : 'recorded',
                    'source' => 'demo',
                    'next_due_at' => now()->addDays(35),
                    'odometer_km' => 18000,
                    'cost' => 4500,
                    'provider' => 'Demo Service Center',
                    'notes' => 'Seeded record for maintenance module walkthrough.',
                    'meta' => ['demo_data' => true],
                ],
            );
        }
    }

    private function seedNotifications(): void
    {
        if (! Schema::hasTable('notification_histories')) {
            return;
        }

        foreach ([
            ['demo-live-trip', 'Demo Live Trip Update', 'DEMO-TRIP-LIVE is currently in transit.', 'dispatch'],
            ['demo-pod-hold', 'Demo POD Review Needed', 'DEMO-TRIP-POD-HOLD needs POD verification before billing.', 'billing'],
            ['demo-maintenance', 'Demo Maintenance Reminder', 'DEMO-TRK-03 is marked under maintenance.', 'maintenance'],
        ] as [$id, $title, $message, $category]) {
            NotificationHistory::query()->updateOrCreate(
                ['notification_id' => $id],
                [
                    'title' => $title,
                    'message' => $message,
                    'category' => $category,
                    'status' => 'sent',
                    'audience' => 'internal',
                    'payload' => ['demo_data' => true],
                    'delivered_at' => now()->subMinutes(20),
                    'delivery_attempts' => 1,
                    'last_delivery_at' => now()->subMinutes(20),
                ],
            );
        }
    }
}
