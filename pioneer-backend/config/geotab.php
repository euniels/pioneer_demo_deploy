<?php

return [
    'database' => env('GEOTAB_DATABASE', ''),
    'username' => env('GEOTAB_USERNAME', ''),
    'password' => env('GEOTAB_PASSWORD', ''),
    'server' => env('GEOTAB_SERVER', 'my.geotab.com'),
    'default_group_id' => env('GEOTAB_DEFAULT_GROUP_ID', ''),
    'feed_default_seed_days' => (int) env('GEOTAB_FEED_DEFAULT_SEED_DAYS', 30),
    'retry_base_ms' => (int) env('GEOTAB_RETRY_BASE_MS', 250),
    'http_feed_sync' => filter_var(env('GEOTAB_HTTP_FEED_SYNC', false), FILTER_VALIDATE_BOOLEAN),
];
