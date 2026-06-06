<?php

namespace App\Services;

use App\Jobs\SendCriticalNotificationEmail;
use App\Models\NotificationHistory;
use App\Models\User;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

class PioneerBackupHealthService
{
    /**
     * @return array<string, mixed>
     */
    public function check(): array
    {
        $path = (string) config('pioneer.backups.path', storage_path('app/backups'));
        $maxAgeHours = max(1, (int) config('pioneer.backups.max_age_hours', 25));
        $latest = $this->latestBackupFile($path);

        if ($latest === null) {
            return [
                'ok' => false,
                'status' => 'missing',
                'path' => $path,
                'latestFile' => null,
                'latestCreatedAt' => null,
                'ageHours' => null,
                'maxAgeHours' => $maxAgeHours,
                'message' => 'No backup file was found in the configured backup path.',
            ];
        }

        $modifiedAt = Carbon::createFromTimestamp((int) ($latest['modifiedAt'] ?? time()));
        $ageHours = round($modifiedAt->diffInMinutes(now()) / 60, 2);
        $ok = $ageHours <= $maxAgeHours;

        return [
            'ok' => $ok,
            'status' => $ok ? 'fresh' : 'stale',
            'path' => $path,
            'latestFile' => $latest['path'],
            'latestCreatedAt' => $modifiedAt->toIso8601String(),
            'ageHours' => $ageHours,
            'maxAgeHours' => $maxAgeHours,
            'message' => $ok
                ? 'Latest backup is within the required freshness window.'
                : 'Latest backup is older than the required freshness window.',
        ];
    }

    /**
     * @param  array<string, mixed>  $result
     */
    public function logResult(array $result): void
    {
        $context = [
            'status' => $result['status'] ?? 'unknown',
            'path' => $result['path'] ?? null,
            'latestFile' => $result['latestFile'] ?? null,
            'latestCreatedAt' => $result['latestCreatedAt'] ?? null,
            'ageHours' => $result['ageHours'] ?? null,
            'maxAgeHours' => $result['maxAgeHours'] ?? null,
        ];

        if (($result['ok'] ?? false) === true) {
            Log::channel('backup')->info('pioneerpath.backup_check.ok', $context);

            return;
        }

        Log::channel('backup')->warning('pioneerpath.backup_check.failed', $context);
    }

    /**
     * @param  array<string, mixed>  $result
     */
    public function alertSuperAdministrators(array $result): void
    {
        if (($result['ok'] ?? false) === true || ! Schema::hasTable('notification_histories')) {
            return;
        }

        $status = (string) ($result['status'] ?? 'failed');
        $notificationId = 'backup-'.$status.'-'.now()->toDateString();

        $notification = NotificationHistory::query()->firstOrCreate(
            ['notification_id' => $notificationId],
            [
                'title' => 'Backup Check Failed',
                'message' => (string) ($result['message'] ?? 'PioneerPath could not confirm a recent database backup.'),
                'category' => 'system',
                'status' => 'sent',
                'audience' => 'super_administrator',
                'payload' => [
                    'url' => '/settings',
                    'icon' => '/icons/Icon-192.png',
                    'tag' => $notificationId,
                    'backupStatus' => $status,
                    'latestFile' => $result['latestFile'] ?? null,
                    'ageHours' => $result['ageHours'] ?? null,
                ],
                'delivered_at' => now(),
            ],
        );

        $recipients = User::query()
            ->where('role', 'super_administrator')
            ->where('status', 'active')
            ->pluck('email')
            ->filter()
            ->map(fn (mixed $email): string => strtolower(trim((string) $email)))
            ->filter(fn (string $email): bool => filter_var($email, FILTER_VALIDATE_EMAIL) !== false)
            ->values()
            ->all();

        if ($recipients !== []) {
            SendCriticalNotificationEmail::dispatch(
                $recipients,
                '[PioneerPath] Backup check failed',
                $notification->message."\n\nStatus: ".$status."\nLatest file: ".(string) ($result['latestFile'] ?? 'none'),
                ['notificationId' => $notificationId, 'backupStatus' => $status],
            );
        }
    }

    /**
     * @return array{path: string, modifiedAt: int}|null
     */
    private function latestBackupFile(string $path): ?array
    {
        if ($path === '' || ! is_dir($path)) {
            return null;
        }

        $patterns = config('pioneer.backups.patterns', ['*.sql', '*.sql.gz']);
        $latest = null;

        foreach ($patterns as $pattern) {
            foreach (glob(rtrim($path, DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR.(string) $pattern) ?: [] as $file) {
                if (! is_file($file)) {
                    continue;
                }

                $modifiedAt = filemtime($file) ?: 0;
                if ($latest === null || $modifiedAt > $latest['modifiedAt']) {
                    $latest = [
                        'path' => Str::replace('\\', '/', $file),
                        'modifiedAt' => $modifiedAt,
                    ];
                }
            }
        }

        return $latest;
    }
}
