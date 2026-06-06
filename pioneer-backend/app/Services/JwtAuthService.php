<?php

namespace App\Services;

use App\Models\JwtRefreshToken;
use App\Models\JwtTokenBlacklist;
use App\Models\User;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;
use RuntimeException;

class JwtAuthService
{
    public function issueTokens(User $user, string $platform = 'web', ?string $ip = null, ?string $userAgent = null): array
    {
        $platform = $this->normalizePlatform($platform);
        $expiresAt = $platform === 'mobile'
            ? now()->addDays(30)
            : now()->addHours(8);

        $jti = (string) Str::uuid();
        $accessToken = $this->encode([
            'sub' => (string) $user->id,
            'role' => (string) $user->role,
            'email' => (string) $user->email,
            'typ' => 'access',
            'jti' => $jti,
            'iat' => now()->timestamp,
            'exp' => $expiresAt->timestamp,
        ]);

        $plainRefreshToken = Str::random(80);
        $refreshExpiresAt = now()->addDays(30);
        JwtRefreshToken::query()->create([
            'user_id' => $user->id,
            'token_hash' => hash('sha256', $plainRefreshToken),
            'platform' => $platform,
            'expires_at' => $refreshExpiresAt,
            'created_ip' => $ip,
            'user_agent' => $userAgent !== null ? Str::limit($userAgent, 500, '') : null,
        ]);

        return [
            'accessToken' => $accessToken,
            'tokenType' => 'Bearer',
            'expiresAt' => $expiresAt->toIso8601String(),
            'expiresIn' => max(0, now()->diffInSeconds($expiresAt, false)),
            'refreshToken' => $plainRefreshToken,
            'refreshExpiresAt' => $refreshExpiresAt->toIso8601String(),
        ];
    }

    public function refresh(string $refreshToken, string $platform = 'web', ?string $ip = null, ?string $userAgent = null): ?array
    {
        $row = JwtRefreshToken::query()
            ->where('token_hash', hash('sha256', trim($refreshToken)))
            ->whereNull('revoked_at')
            ->where('expires_at', '>', now())
            ->first();

        if ($row === null) {
            return null;
        }

        $user = User::query()->find($row->user_id);
        if ($user === null || strtolower((string) ($user->status ?? 'active')) !== 'active') {
            return null;
        }

        $row->forceFill(['revoked_at' => now()])->save();

        return $this->issueTokens($user, $platform, $ip, $userAgent);
    }

    public function verifyAccessToken(string $token): ?array
    {
        try {
            $payload = $this->decode($token);
        } catch (RuntimeException) {
            return null;
        }

        if (($payload['typ'] ?? null) !== 'access') {
            return null;
        }

        $jti = trim((string) ($payload['jti'] ?? ''));
        if ($jti === '' || JwtTokenBlacklist::query()->where('jti', $jti)->where('expires_at', '>', now())->exists()) {
            return null;
        }

        $user = User::query()->find($payload['sub'] ?? null);
        if ($user === null || strtolower((string) ($user->status ?? 'active')) !== 'active') {
            return null;
        }

        $payload['user'] = $user;

        return $payload;
    }

    public function blacklist(string $token, string $reason = 'logout'): void
    {
        try {
            $payload = $this->decode($token, allowExpired: true);
        } catch (RuntimeException) {
            return;
        }

        $jti = trim((string) ($payload['jti'] ?? ''));
        if ($jti === '') {
            return;
        }

        JwtTokenBlacklist::query()->updateOrCreate(
            ['jti' => $jti],
            [
                'user_id' => $payload['sub'] ?? null,
                'expires_at' => Carbon::createFromTimestamp((int) ($payload['exp'] ?? now()->timestamp)),
                'reason' => $reason,
            ]
        );
    }

    public function revokeRefreshToken(string $refreshToken): void
    {
        JwtRefreshToken::query()
            ->where('token_hash', hash('sha256', trim($refreshToken)))
            ->whereNull('revoked_at')
            ->update(['revoked_at' => now(), 'updated_at' => now()]);
    }

    private function encode(array $payload): string
    {
        $header = ['alg' => 'HS256', 'typ' => 'JWT'];
        $segments = [
            $this->base64UrlEncode(json_encode($header, JSON_THROW_ON_ERROR)),
            $this->base64UrlEncode(json_encode($payload, JSON_THROW_ON_ERROR)),
        ];
        $segments[] = $this->signature($segments[0].'.'.$segments[1]);

        return implode('.', $segments);
    }

    private function decode(string $token, bool $allowExpired = false): array
    {
        $parts = explode('.', trim($token));
        if (count($parts) !== 3) {
            throw new RuntimeException('Malformed token.');
        }

        [$encodedHeader, $encodedPayload, $signature] = $parts;
        if (! hash_equals($this->signature($encodedHeader.'.'.$encodedPayload), $signature)) {
            throw new RuntimeException('Invalid token signature.');
        }

        $payload = json_decode($this->base64UrlDecode($encodedPayload), true, 512, JSON_THROW_ON_ERROR);
        if (! is_array($payload)) {
            throw new RuntimeException('Invalid token payload.');
        }

        if (! $allowExpired && (int) ($payload['exp'] ?? 0) <= now()->timestamp) {
            throw new RuntimeException('Expired token.');
        }

        return $payload;
    }

    private function signature(string $value): string
    {
        return $this->base64UrlEncode(hash_hmac('sha256', $value, $this->secret(), true));
    }

    private function secret(): string
    {
        $key = (string) config('app.key');
        if (str_starts_with($key, 'base64:')) {
            $decoded = base64_decode(substr($key, 7), true);
            if ($decoded !== false) {
                return $decoded;
            }
        }

        return $key !== '' ? $key : 'pioneerpath-local-jwt-secret';
    }

    private function base64UrlEncode(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }

    private function base64UrlDecode(string $value): string
    {
        return base64_decode(strtr($value.str_repeat('=', (4 - strlen($value) % 4) % 4), '-_', '+/'), true) ?: '';
    }

    private function normalizePlatform(string $platform): string
    {
        return strtolower(trim($platform)) === 'mobile' ? 'mobile' : 'web';
    }
}
