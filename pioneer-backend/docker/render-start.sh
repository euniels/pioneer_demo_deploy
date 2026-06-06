#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-10000}"

sed -ri "s/^Listen .*/Listen ${PORT}/" /etc/apache2/ports.conf
sed -ri "s/<VirtualHost \*:[0-9]+>/<VirtualHost *:${PORT}>/" /etc/apache2/sites-available/000-default.conf

php artisan optimize:clear --no-interaction || true

if [[ "${RUN_MIGRATIONS:-true}" == "true" ]]; then
    php artisan migrate --force --no-interaction
fi

php artisan storage:link --no-interaction || true
php artisan config:cache --no-interaction
php artisan route:cache --no-interaction || true
php artisan view:cache --no-interaction || true

exec apache2-foreground
