# PioneerPath Backend Deployment Notes

## Deployment Checklist

Run this first on the target server after `.env` has been created and before
opening the system to users:

```bash
php artisan pioneer:setup-check
```

Fix every failed check before production traffic is allowed. The command checks
debug mode, app key, MySQL, Redis cache/queue, GeoTab credentials, VAPID keys,
Google Maps enrichment keys when enabled, mail delivery configuration,
migration status, and GeoTab feed seed status.

## Environment Separation

Use `.env.example` as the production template. It is grouped into required
sections for Application, Database, Cache and Queue, GeoTab, Google Maps, Push,
Mail, Logging, SSE, and backups. Production rules:

- `APP_DEBUG=false`
- `DB_CONNECTION=mysql`
- `CACHE_DRIVER=redis` and `CACHE_STORE=redis`
- `QUEUE_CONNECTION=redis`
- `PIONEER_SSE_ENABLED=true` only when the runtime can support long-lived
  streams
- `PIONEER_CORS_ALLOWED_ORIGINS` must list the real Flutter web domain, not `*`
- never commit real database, GeoTab, VAPID, Google Maps, mail, or signing
  secrets

Password reset email links use `PIONEER_FRONTEND_URL`; set it to the public
Flutter web URL, for example `https://app.your-pioneerpath-domain.com`.

## Password Reset Email

Production password reset uses these routes:

- `POST /api/fleet/auth/forgot-password`
- `POST /api/fleet/auth/reset-password`

The first route sends a 60-minute reset link to the staff member's email. The
second route consumes the token, sets a bcrypt-hashed password, deletes the
token, and signs the user in. Configure a real `MAIL_MAILER`, `MAIL_HOST`,
`MAIL_PORT`, `MAIL_USERNAME`, `MAIL_PASSWORD`, and `MAIL_FROM_ADDRESS` before
enabling production users. The `log` mailer is acceptable only for local
development.

## Flutter Web Production Build

Build Flutter web with CanvasKit for consistent rendering:

```bash
flutter build web --release --web-renderer canvaskit \
  --dart-define=API_BASE_URL=https://api.your-pioneerpath-domain.com/api \
  --dart-define=PIONEER_SSE_MODE=enabled
```

Optional Google Maps renderer key for web can be supplied at build time when
you do not want to rely on the backend runtime config:

```bash
--dart-define=GOOGLE_MAPS_API_KEY=your-browser-restricted-key
```

Prefer the backend `/api/fleet/maps/config` endpoint for runtime key delivery
when possible, so the same Flutter artifact can move across environments.

## Android Release Signing

Android release builds require a private signing key. These files and passwords
must never be committed:

- keystore file
- key alias
- key password
- store password

Create a `key.properties` file outside source control or inject the values from
CI/CD secrets, then build:

```bash
flutter build apk --release
flutter build appbundle --release
```

Back up the signing key separately from the codebase. If the signing key is
lost, installed Android builds signed with that key cannot be updated in place.

## Redis Cache And Queue

Production must not use the file cache or sync queue drivers. Multiple PHP-FPM
workers and SSE clients write cache/feed/notification state concurrently, so use
Redis for both cache and queue.

Required `.env` values:

```env
CACHE_STORE=redis
QUEUE_CONNECTION=redis
REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379
REDIS_DB=0
REDIS_CACHE_DB=1
REDIS_QUEUE=default
```

Run a queue worker under Supervisor, systemd, Laravel Cloud workers, or an
equivalent process manager:

```bash
php artisan queue:work --queue=default,write-back,notifications
```

Recommended worker rules:

- Keep at least one worker always running.
- Configure the process manager to restart a crashed worker automatically with a
  5 second delay before restart.
- Restart workers during deployments after `php artisan config:cache`.
- Monitor failed jobs and queue depth.
- Use separate workers for `write-back` when GeoTab write volume increases.

## Scheduler

Production cron should invoke Laravel's scheduler every minute:

```cron
* * * * * php /path/to/artisan schedule:run >> /dev/null 2>&1
```

Scheduled operational checks include:

- `pioneer:backup-check` daily at `03:00`
- `pioneer:integrity-check` daily at `03:15`

## SSE Runtime

Do not use `php artisan serve` for production SSE. Use a multi-worker runtime
such as Nginx + PHP-FPM or an equivalent Laravel Cloud setup so long-lived
`/api/fleet/stream` connections do not block normal API traffic.

## Error Monitoring And Logs

PioneerPath writes structured production logs to daily rotated files in
`storage/logs`:

- `geotab.log` for GeoTab feed/API timing and route resolution.
- `write-back.log` for GeoTab write-back job execution.
- `auth-events.log` for login attempts and account lock signals.
- `billing.log` for invoice creation, updates, voids, and ERP references.
- `notifications.log` for web push delivery summaries.
- `backup.log` for backup freshness checks.
- `integrity.log` for read-only data consistency findings.
- `app-errors.log` for unhandled backend exceptions and Flutter client reports.

Keep `LOG_DAILY_DAYS` set to a bounded value, for example `14`, so log files do
not grow forever. `SENTRY_LARAVEL_DSN` is reserved as an optional future hook if
the team chooses to add Sentry; no Sentry credentials should be committed.

The unauthenticated uptime endpoint is:

```text
GET /api/health
```

It reports database, cache, queue worker, scheduler, disk, and PHP memory status
without exposing credentials. It returns HTTP `503` when a critical dependency
is unavailable.

## Database Backup And Restore

Production MySQL backups must be automated independently of the application
server. The recommended baseline is a daily compressed dump:

```bash
mysqldump --single-transaction --quick --routines --triggers \
  -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" \
  | gzip > "pioneerpath-$(date +%Y-%m-%d).sql.gz"
```

Retention policy:

- Keep daily backups for 30 days.
- Keep weekly backups for 6 months.
- Store backups off the application server. Acceptable destinations include an
  S3-compatible bucket, Google Cloud Storage, Azure Blob Storage, a managed
  database backup service, or a secured network backup share mounted read-only
  for verification.

The application server can verify freshness through:

```bash
php artisan pioneer:backup-check
```

Configure the location/pattern that the check scans:

```env
PIONEER_BACKUP_PATH=/mnt/pioneerpath-backups/mysql
PIONEER_BACKUP_PATTERNS=*.sql,*.sql.gz,*.dump,*.backup,*.bak
PIONEER_BACKUP_MAX_AGE_HOURS=25
```

`pioneer:backup-check` fails when no matching backup exists or when the newest
backup is older than 25 hours. It logs to `storage/logs/backup.log` and creates
a Super Administrator system notification when the backup is missing or stale.

Restore verification must be practiced on a schedule, not only during an
incident. At least monthly, restore the newest backup to a separate test
database and run:

```bash
mysql -h "$TEST_DB_HOST" -u "$TEST_DB_USERNAME" -p"$TEST_DB_PASSWORD" "$TEST_DB_DATABASE" \
  < restored-pioneerpath.sql
php artisan migrate:status
php artisan pioneer:integrity-check
```

Never restore directly over production unless the incident response owner has
approved the rollback plan.

## Data Integrity Checks

Run this daily through the Laravel scheduler and any time after a restore:

```bash
php artisan pioneer:integrity-check
```

The command is read-only. It reports:

- invoice references whose `trip_id` does not exist in the current trip index;
- GPS logs with a missing or unknown `trip_id`;
- pending or approved GeoTab write-back jobs older than 24 hours;
- active trips without a GPS log in the last 4 hours when the LogRecord feed is
  seeded.

Findings are logged to `storage/logs/integrity.log`. The command returns exit
code `1` when anomalies are present so monitoring can alert the operations team.
