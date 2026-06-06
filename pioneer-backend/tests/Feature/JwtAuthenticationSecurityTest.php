<?php

use App\Models\LoginAttemptLog;
use App\Models\NotificationHistory;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Mail;
use Tests\TestCase;

uses(RefreshDatabase::class);

function jwtTestUser(string $role = 'super_administrator', array $overrides = []): User
{
    return User::query()->create([
        'name' => $overrides['name'] ?? 'JWT Test User',
        'email' => $overrides['email'] ?? strtolower($role).'@jwt.test',
        'password' => Hash::make($overrides['password'] ?? 'SecurePass123!'),
        'role' => $role,
        'status' => $overrides['status'] ?? 'active',
        'must_change_password' => $overrides['must_change_password'] ?? false,
    ]);
}

function jwtLogin(TestCase $test, User $user, string $password = 'SecurePass123!'): array
{
    return $test->postJson('/api/fleet/users/login-check', [
        'username' => $user->email,
        'password' => $password,
        'platform' => 'web',
    ])->assertOk()->json('data.auth');
}

test('managed login returns signed jwt and protected endpoints use bearer role', function (): void {
    $user = jwtTestUser('dispatcher');
    $auth = jwtLogin($this, $user);

    expect($auth['accessToken'])->toBeString()->not->toBe('')
        ->and($auth['refreshToken'])->toBeString()->not->toBe('')
        ->and($auth['expiresAt'])->toBeString();

    $this->withToken($auth['accessToken'])
        ->getJson('/api/fleet/trips')
        ->assertOk();

    $this->withToken($auth['accessToken'])
        ->postJson('/api/billing/invoices', ['tripId' => 'TRP-DENIED'])
        ->assertForbidden();
});

test('client supplied pioneer role header cannot override invalid bearer token', function (): void {
    $this->withHeaders(['X-Pioneer-Role' => 'super_administrator'])
        ->withToken('not-a-real-token')
        ->getJson('/api/fleet/users')
        ->assertUnauthorized();
});

test('refresh endpoint rotates refresh token and logout blacklists access token', function (): void {
    $user = jwtTestUser('super_administrator');
    $auth = jwtLogin($this, $user);

    $refreshed = $this->postJson('/api/fleet/auth/refresh', [
        'refreshToken' => $auth['refreshToken'],
        'platform' => 'web',
    ])->assertOk()->json('data.auth');

    expect($refreshed['accessToken'])->toBeString()->not->toBe($auth['accessToken'])
        ->and($refreshed['refreshToken'])->toBeString()->not->toBe($auth['refreshToken']);

    $this->withToken($refreshed['accessToken'])
        ->postJson('/api/fleet/auth/logout', [
            'refreshToken' => $refreshed['refreshToken'],
        ])->assertOk();

    $this->withToken($refreshed['accessToken'])
        ->getJson('/api/fleet/users')
        ->assertUnauthorized();
});

test('must change password user can update password and clear first login flag', function (): void {
    $user = jwtTestUser('dispatcher', ['must_change_password' => true]);
    $auth = jwtLogin($this, $user);

    $this->withToken($auth['accessToken'])
        ->getJson('/api/fleet/trips')
        ->assertStatus(423);

    $this->withToken($auth['accessToken'])
        ->postJson('/api/fleet/auth/change-password', [
            'currentPassword' => 'SecurePass123!',
            'newPassword' => 'NewSecurePass123!',
        ])
        ->assertOk()
        ->assertJsonPath('data.mustChangePassword', false);

    expect(Hash::check('NewSecurePass123!', $user->refresh()->password))->toBeTrue();
});

test('forgot password issues expiring token and reset consumes it', function (): void {
    Mail::fake();
    $user = jwtTestUser('dispatcher', ['email' => 'reset-flow@jwt.test']);

    $this->postJson('/api/fleet/auth/forgot-password', [
        'email' => $user->email,
    ])->assertOk()
        ->assertJsonPath('data.sent', true);

    $row = DB::table('password_reset_tokens')->where('email', $user->email)->first();
    expect($row)->not->toBeNull();

    $plainToken = 'known-reset-token';
    DB::table('password_reset_tokens')->where('email', $user->email)->update([
        'token' => Hash::make($plainToken),
        'created_at' => now(),
    ]);

    $response = $this->postJson('/api/fleet/auth/reset-password', [
        'email' => $user->email,
        'token' => $plainToken,
        'password' => 'ResetSecure123!',
        'platform' => 'web',
    ])->assertOk();

    expect(Hash::check('ResetSecure123!', $user->refresh()->password))->toBeTrue()
        ->and($response->json('data.auth.accessToken'))->toBeString()->not->toBe('')
        ->and(DB::table('password_reset_tokens')->where('email', $user->email)->exists())->toBeFalse();
});

test('five failed login attempts from one ip locks that ip for fifteen minutes', function (): void {
    $user = jwtTestUser('dispatcher', ['email' => 'ip-lock@jwt.test']);

    for ($i = 0; $i < 5; $i++) {
        $this->withServerVariables(['REMOTE_ADDR' => '10.10.10.10'])
            ->postJson('/api/fleet/users/login-check', [
                'username' => $user->email,
                'password' => 'wrong-password',
            ])->assertUnauthorized();
    }

    $this->withServerVariables(['REMOTE_ADDR' => '10.10.10.10'])
        ->postJson('/api/fleet/users/login-check', [
            'username' => $user->email,
            'password' => 'SecurePass123!',
        ])->assertStatus(429);

    expect(LoginAttemptLog::query()->where('ip_address', '10.10.10.10')->count())->toBeGreaterThanOrEqual(6);
});

test('ten failed account attempts lock the account and notify super administrator', function (): void {
    $user = jwtTestUser('dispatcher', ['email' => 'account-lock@jwt.test']);

    for ($i = 0; $i < 10; $i++) {
        $this->withServerVariables(['REMOTE_ADDR' => '10.10.20.'.($i + 1)])
            ->postJson('/api/fleet/users/login-check', [
                'username' => $user->email,
                'password' => 'wrong-password',
            ])->assertUnauthorized();
    }

    expect($user->refresh()->status)->toBe('locked')
        ->and($user->failed_login_count)->toBe(10)
        ->and(NotificationHistory::query()
            ->where('notification_id', 'account-lock-'.$user->id)
            ->exists())->toBeTrue();

    $this->withServerVariables(['REMOTE_ADDR' => '10.10.30.1'])
        ->postJson('/api/fleet/users/login-check', [
            'username' => $user->email,
            'password' => 'SecurePass123!',
        ])->assertStatus(423);
});
