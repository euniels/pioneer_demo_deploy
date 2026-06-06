<?php

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Hash;

uses(RefreshDatabase::class);

test('super administrator can create list update reset and deactivate user accounts', function () {
    $create = $this->postJson('/api/fleet/users', [
        'fullName' => 'Dispatch Lead',
        'email' => 'dispatch.lead@example.test',
        'role' => 'dispatcher',
        'phone' => '+63 917 000 9999',
        'temporaryPassword' => 'TempPass123!',
        'status' => 'active',
        'actor' => 'super@example.test',
        'actorRole' => 'super_administrator',
    ])
        ->assertOk()
        ->assertJsonPath('data.fullName', 'Dispatch Lead')
        ->assertJsonPath('data.role', 'dispatcher')
        ->assertJsonPath('data.status', 'active')
        ->assertJsonPath('data.mustChangePassword', true)
        ->assertJsonPath('data.temporaryPassword', 'TempPass123!');

    $userId = $create->json('data.id');
    $user = User::query()->findOrFail($userId);
    expect(Hash::check('TempPass123!', $user->password))->toBeTrue()
        ->and($user->password)->not->toBe('TempPass123!');

    $this->getJson('/api/fleet/users?role=dispatcher&status=active')
        ->assertOk()
        ->assertJsonPath('data.0.email', 'dispatch.lead@example.test')
        ->assertJsonMissingPath('data.0.password');

    $this->patchJson('/api/fleet/users/'.$userId, [
        'fullName' => 'Dispatch Lead Updated',
        'role' => 'fleet_manager',
        'actor' => 'super@example.test',
        'actorRole' => 'super_administrator',
    ])
        ->assertOk()
        ->assertJsonPath('data.fullName', 'Dispatch Lead Updated')
        ->assertJsonPath('data.role', 'fleet_manager');

    $detail = $this->getJson('/api/fleet/users/'.$userId)
        ->assertOk()
        ->assertJsonPath('data.activityLog.0.action', 'created');
    expect(collect($detail->json('data.activityLog'))->pluck('action'))->toContain('role_changed');

    $reset = $this->postJson('/api/fleet/users/'.$userId.'/reset-password', [
        'actor' => 'super@example.test',
        'actorRole' => 'super_administrator',
    ])->assertOk();
    expect($reset->json('data.temporaryPassword'))->toBeString()->not->toBe('');

    $this->deleteJson('/api/fleet/users/'.$userId, [
        'reason' => 'User moved departments.',
        'actor' => 'super@example.test',
        'actorRole' => 'super_administrator',
    ])
        ->assertOk()
        ->assertJsonPath('data.status', 'inactive')
        ->assertJsonPath('data.isActive', false);

    $this->postJson('/api/fleet/users/login-check', [
        'username' => 'dispatch.lead@example.test',
        'password' => $reset->json('data.temporaryPassword'),
    ])->assertForbidden();
});

test('system administrator cannot manage peer or higher administrator accounts', function () {
    $this->postJson('/api/fleet/users', [
        'fullName' => 'New Super Admin',
        'email' => 'super.new@example.test',
        'role' => 'super_administrator',
        'temporaryPassword' => 'TempPass123!',
        'actorRole' => 'system_administrator',
    ])->assertForbidden();

    $create = $this->postJson('/api/fleet/users', [
        'fullName' => 'Accounting Staff',
        'email' => 'accounting@example.test',
        'role' => 'accounting_staff',
        'temporaryPassword' => 'TempPass123!',
        'actorRole' => 'system_administrator',
    ])->assertOk();

    $this->patchJson('/api/fleet/users/'.$create->json('data.id'), [
        'role' => 'system_administrator',
        'actorRole' => 'system_administrator',
    ])->assertForbidden();
});

test('driver user deactivation is blocked while assigned to an active trip', function () {
    $create = $this->postJson('/api/fleet/users', [
        'fullName' => 'Active Trip Driver',
        'email' => 'active.driver@example.test',
        'role' => 'driver',
        'temporaryPassword' => 'TempPass123!',
        'actorRole' => 'super_administrator',
    ])->assertOk();

    $this->postJson('/api/fleet/trips', [
        'tripId' => 'TRP-USER-ACTIVE',
        'customer' => 'CRUD Test Client',
        'origin' => 'Pioneer Warehouse',
        'destination' => 'Client Site',
        'driver' => 'Active Trip Driver',
        'vehicle' => 'PTC-101',
        'amount' => 1500,
        'status' => 'dispatched',
    ])->assertOk();

    $this->deleteJson('/api/fleet/users/'.$create->json('data.id'), [
        'reason' => 'Attempting while trip active.',
        'actorRole' => 'super_administrator',
    ])->assertStatus(423);

    $this->deleteJson('/api/fleet/users/'.$create->json('data.id').'/permanent', [
        'actorRole' => 'super_administrator',
    ])
        ->assertStatus(423)
        ->assertJsonPath('message', 'This user has active trips and cannot be deleted.');
});

test('hard delete only removes unused user accounts without audit or administrator dependencies', function () {
    $unused = User::query()->create([
        'name' => 'Unused Account',
        'email' => 'unused.delete@example.test',
        'password' => Hash::make('TempPass123!'),
        'role' => 'dispatcher',
        'status' => 'active',
        'activity_log' => [],
    ]);

    $this->deleteJson('/api/fleet/users/'.$unused->id.'/permanent', [
        'actorRole' => 'super_administrator',
    ])
        ->assertOk()
        ->assertJsonPath('data.deleted', true);
    expect(User::query()->find($unused->id))->toBeNull();

    $audited = User::query()->create([
        'name' => 'Audited Account',
        'email' => 'audited.delete@example.test',
        'password' => Hash::make('TempPass123!'),
        'role' => 'dispatcher',
        'status' => 'active',
        'activity_log' => [['action' => 'created', 'timestamp' => now()->toIso8601String()]],
    ]);

    $this->deleteJson('/api/fleet/users/'.$audited->id.'/permanent', [
        'actorRole' => 'super_administrator',
    ])
        ->assertStatus(423)
        ->assertJsonPath('message', 'This user has audit history and cannot be deleted.');

    $soleSuperAdministrator = User::query()->create([
        'name' => 'Only Super Admin',
        'email' => 'only.super@example.test',
        'password' => Hash::make('TempPass123!'),
        'role' => 'super_administrator',
        'status' => 'active',
        'activity_log' => [],
    ]);

    $this->deleteJson('/api/fleet/users/'.$soleSuperAdministrator->id.'/permanent', [
        'actorRole' => 'super_administrator',
    ])
        ->assertStatus(423)
        ->assertJsonPath('message', 'Cannot delete the only Super Admin.');
});

test('active managed user can log in and records last login timestamp', function () {
    User::query()->create([
        'name' => 'Managed Login User',
        'email' => 'managed.login@example.test',
        'password' => Hash::make('TempPass123!'),
        'role' => 'dispatcher',
        'status' => 'active',
        'must_change_password' => true,
    ]);

    $this->postJson('/api/fleet/users/login-check', [
        'username' => 'managed.login@example.test',
        'password' => 'TempPass123!',
    ])
        ->assertOk()
        ->assertJsonPath('data.email', 'managed.login@example.test')
        ->assertJsonPath('data.role', 'dispatcher')
        ->assertJsonPath('data.mustChangePassword', true);

    expect(User::query()->where('email', 'managed.login@example.test')->first()?->last_login_at)->not->toBeNull();
});

test('audit logs expose login session details and user before after diffs', function () {
    $user = User::query()->create([
        'name' => 'Audit Review User',
        'email' => 'audit.review@example.test',
        'password' => Hash::make('TempPass123!'),
        'role' => 'dispatcher',
        'status' => 'active',
        'must_change_password' => true,
        'activity_log' => [],
    ]);

    $this->withServerVariables(['REMOTE_ADDR' => '203.0.113.10'])
        ->postJson('/api/fleet/users/login-check', [
            'username' => 'audit.review@example.test',
            'password' => 'TempPass123!',
        ])
        ->assertOk();

    $this->patchJson('/api/fleet/users/'.$user->id, [
        'role' => 'fleet_manager',
        'actor' => 'super@example.test',
        'actorRole' => 'super_administrator',
    ])->assertOk();

    $this->getJson('/api/fleet/audit-logs?actionType=login&actor=audit.review@example.test')
        ->assertOk()
        ->assertJsonPath('data.0.actionLabel', 'Login')
        ->assertJsonPath('data.0.entityType', 'session')
        ->assertJsonPath('data.0.actorEmail', 'audit.review@example.test')
        ->assertJsonPath('data.0.ipAddress', '203.0.113.10')
        ->assertJsonPath('data.0.isSessionEvent', true);

    $roleChange = $this->getJson('/api/fleet/audit-logs?actionType=role_change&actor=super@example.test')
        ->assertOk()
        ->assertJsonPath('data.0.actionLabel', 'Role Change')
        ->assertJsonPath('data.0.before.role', 'dispatcher')
        ->assertJsonPath('data.0.after.role', 'fleet_manager');

    expect($roleChange->json('data.0.displayTimestamp'))->toContain(',')->not->toContain('T');
});
