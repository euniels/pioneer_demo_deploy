# PioneerPath Deployment Notes

PioneerPath production should run the Laravel backend behind a multi-worker
PHP runtime. Do not use `php artisan serve` for production or for validating
long-lived Server-Sent Events (SSE): the built-in PHP server can block normal
API traffic while one browser holds `/api/fleet/stream` open.

## Realtime SSE Flags

Backend:

```env
PIONEER_SSE_ENABLED=true
```

Flutter build flag:

```bash
flutter build web --dart-define=PIONEER_SSE_MODE=enabled
```

Supported `PIONEER_SSE_MODE` values:

- `enabled`: always open the SSE connection.
- `disabled`: skip SSE and use polling fallback.
- `auto`: release builds use SSE; debug builds use polling fallback.

Use `enabled` for staging/local SSE validation when the backend is served by a
multi-worker runtime such as Nginx + PHP-FPM. Use `disabled` only for emergency
fallback or single-worker local development.

## Nginx + PHP-FPM SSE Configuration

For PHP-FPM, turn off buffering and use long read timeouts for the stream route:

```nginx
location = /api/fleet/stream {
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME $realpath_root/index.php;
    fastcgi_param DOCUMENT_ROOT $realpath_root;
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;

    fastcgi_buffering off;
    fastcgi_read_timeout 3600s;
    fastcgi_send_timeout 3600s;
    add_header X-Accel-Buffering no;
    add_header Cache-Control "no-cache, no-transform";
}
```

If Nginx is reverse proxying to another PHP application server instead of
FastCGI, use the equivalent proxy settings:

```nginx
location /api/fleet/stream {
    proxy_pass http://pioneerpath_backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    add_header X-Accel-Buffering no;
}
```

Keep normal API routes buffered for throughput; only the SSE route needs this
long-lived streaming behavior.

## PHP-FPM Worker Sizing

Each connected SSE browser session occupies a PHP-FPM worker. Size the pool for
expected SSE clients plus normal API traffic:

```ini
pm = dynamic
pm.max_children = 40
pm.start_servers = 8
pm.min_spare_servers = 8
pm.max_spare_servers = 16
pm.max_requests = 500
request_terminate_timeout = 0
```

Example sizing: 20 concurrent dispatch/live-tracking users plus 10 normal API
workers plus safety headroom means `pm.max_children` should be at least 35-40.
Raise this with real traffic data and available server memory.

## Health Validation

Check SSE status through:

```bash
curl https://your-domain.example/api/fleet/geotab/health
```

The response includes:

- `sse.enabled`
- `sse.active`
- `sse.mode`
- `sse.activeClients`
- `sse.active_clients`

In production the expected mode is `stream`. In `php artisan serve`, the backend
reports `oneshot-dev-server` unless explicitly overridden for manual testing.

