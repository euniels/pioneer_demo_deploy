<?php

use Illuminate\Foundation\Testing\RefreshDatabase;

uses(RefreshDatabase::class);

function pioneerRoleHeader(string $role): array
{
    return ['X-Pioneer-Role' => $role];
}

test('system administrator cannot access system settings but can manage lower user roles', function (): void {
    $this->withHeaders(pioneerRoleHeader('system_administrator'))
        ->getJson('/api/fleet/settings/system')
        ->assertForbidden();

    $this->withHeaders(pioneerRoleHeader('system_administrator'))
        ->postJson('/api/fleet/users', [
            'fullName' => 'Dispatcher Matrix',
            'email' => 'dispatcher.matrix@example.test',
            'role' => 'dispatcher',
            'temporaryPassword' => 'TempPass123!',
            'actorRole' => 'system_administrator',
        ])
        ->assertOk();

    $this->withHeaders(pioneerRoleHeader('system_administrator'))
        ->postJson('/api/fleet/users', [
            'fullName' => 'Peer Admin',
            'email' => 'peer.admin@example.test',
            'role' => 'system_administrator',
            'temporaryPassword' => 'TempPass123!',
            'actorRole' => 'system_administrator',
        ])
        ->assertForbidden();
});

test('fleet manager can edit vehicles routes zones and maintenance but cannot delete entities', function (): void {
    $this->withHeaders(pioneerRoleHeader('fleet_manager'))
        ->postJson('/api/fleet/vehicles/manual', [
            'plateNumber' => 'FM-101',
            'vehicleType' => 'Light Commercial Vehicle',
            'fuelType' => 'Diesel',
            'cargoCapacityKg' => 1200,
            'registrationExpiryDate' => now()->addYear()->toDateString(),
        ])
        ->assertOk();

    $this->withHeaders(pioneerRoleHeader('fleet_manager'))
        ->deleteJson('/api/fleet/vehicles/manual/1', ['reason' => 'Matrix test'])
        ->assertForbidden();

    $this->withHeaders(pioneerRoleHeader('fleet_manager'))
        ->getJson('/api/billing/invoices')
        ->assertOk();

    $this->withHeaders(pioneerRoleHeader('fleet_manager'))
        ->postJson('/api/billing/invoices', ['tripId' => 'TRP-NOPE'])
        ->assertForbidden();
});

test('dispatcher can manage trips but cannot access billing or settings', function (): void {
    $this->withHeaders(pioneerRoleHeader('dispatcher'))
        ->postJson('/api/fleet/trips', [
            'tripId' => 'TRP-DISPATCH-MATRIX',
            'customer' => 'Matrix Client',
            'origin' => 'Depot',
            'destination' => 'Customer',
            'driver' => 'Driver One',
            'vehicle' => 'PTC-100',
            'amount' => 1500,
            'status' => 'pending',
        ])
        ->assertOk();

    $this->withHeaders(pioneerRoleHeader('dispatcher'))
        ->getJson('/api/billing/invoices')
        ->assertForbidden();

    $this->withHeaders(pioneerRoleHeader('dispatcher'))
        ->getJson('/api/fleet/settings/system')
        ->assertForbidden();
});

test('accounting staff can manage invoices and read core records only', function (): void {
    $this->withHeaders(pioneerRoleHeader('super_administrator'))
        ->postJson('/api/fleet/trips', [
            'tripId' => 'TRP-MANUAL-ACCOUNTING',
            'customer' => 'Matrix Client',
            'origin' => 'Depot',
            'destination' => 'Customer',
            'driver' => 'Driver One',
            'vehicle' => 'PTC-100',
            'amount' => 1500,
            'status' => 'completed',
        ])
        ->assertOk();

    $this->withHeaders(pioneerRoleHeader('accounting_staff'))
        ->getJson('/api/fleet/trips')
        ->assertOk();

    $this->withHeaders(pioneerRoleHeader('accounting_staff'))
        ->postJson('/api/fleet/trips', [
            'tripId' => 'TRP-ACCOUNTING-NO',
            'customer' => 'Matrix Client',
            'origin' => 'Depot',
            'destination' => 'Customer',
        ])
        ->assertForbidden();

    $this->withHeaders(pioneerRoleHeader('accounting_staff'))
        ->postJson('/api/billing/invoices', [
            'tripId' => 'TRP-MANUAL-ACCOUNTING',
            'overrideReason' => 'Matrix edge invoice.',
            'lineItems' => [
                ['label' => 'Base delivery charge', 'amount' => 1000],
            ],
        ])
        ->assertOk();
});

test('driver cannot manage fleet entities but can submit pod', function (): void {
    $this->withHeaders(pioneerRoleHeader('driver'))
        ->postJson('/api/fleet/vehicles/manual', [
            'plateNumber' => 'DR-NO',
            'cargoCapacityKg' => 1000,
            'registrationExpiryDate' => now()->addYear()->toDateString(),
        ])
        ->assertForbidden();

    $this->withHeaders(pioneerRoleHeader('driver'))
        ->postJson('/api/fleet/pod/TRP-DRIVER-POD', [
            'recipientName' => 'Receiver',
            'notes' => 'Delivered.',
            'status' => 'submitted',
        ])
        ->assertOk();
});
