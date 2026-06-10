<?php

return [
    /*
    |--------------------------------------------------------------------------
    | Pioneer runtime flags
    |--------------------------------------------------------------------------
    |
    | Centralized flags for feature toggles and UI helpers consumed by the
    | backend. These are intended to be read from environment for deploy-time
    | overrides.
    |
    */

    'show_mock_data' => (bool) env('PIONEER_SHOW_MOCK_DATA', true),
    'mock_indicator_label' => env('PIONEER_MOCK_INDICATOR_LABEL', 'Sample'),
    'frontend_url' => env('PIONEER_FRONTEND_URL', env('APP_URL', '')),
    'cors_allowed_origins' => env('PIONEER_CORS_ALLOWED_ORIGINS', ''),
    'sse_enabled' => filter_var(env('PIONEER_SSE_ENABLED', true), FILTER_VALIDATE_BOOLEAN),

    'rate_limits' => [
        'login' => [
            'max_attempts' => (int) env('PIONEER_RATE_LIMIT_LOGIN_MAX', 10),
            'window_seconds' => (int) env('PIONEER_RATE_LIMIT_LOGIN_WINDOW', 60),
        ],
        'client_errors' => [
            'max_attempts' => (int) env('PIONEER_RATE_LIMIT_CLIENT_ERRORS_MAX', 30),
            'window_seconds' => (int) env('PIONEER_RATE_LIMIT_CLIENT_ERRORS_WINDOW', 60),
        ],
        'writeback' => [
            'max_attempts' => (int) env('PIONEER_RATE_LIMIT_WRITEBACK_MAX', 30),
            'window_seconds' => (int) env('PIONEER_RATE_LIMIT_WRITEBACK_WINDOW', 60),
        ],
        'mutations' => [
            'max_attempts' => (int) env('PIONEER_RATE_LIMIT_MUTATIONS_MAX', 120),
            'window_seconds' => (int) env('PIONEER_RATE_LIMIT_MUTATIONS_WINDOW', 60),
        ],
        'reads' => [
            'max_attempts' => (int) env('PIONEER_RATE_LIMIT_READS_MAX', 300),
            'window_seconds' => (int) env('PIONEER_RATE_LIMIT_READS_WINDOW', 60),
        ],
        'live' => [
            'max_attempts' => (int) env('PIONEER_RATE_LIMIT_LIVE_MAX', 600),
            'window_seconds' => (int) env('PIONEER_RATE_LIMIT_LIVE_WINDOW', 60),
        ],
        'sse_clients_per_user' => (int) env('PIONEER_RATE_LIMIT_SSE_CLIENTS_PER_USER', 5),
    ],

    'backups' => [
        'path' => env('PIONEER_BACKUP_PATH', storage_path('app/backups')),
        'patterns' => array_values(array_filter(array_map(
            'trim',
            explode(',', env('PIONEER_BACKUP_PATTERNS', '*.sql,*.sql.gz,*.dump,*.backup,*.bak'))
        ))),
        'max_age_hours' => (int) env('PIONEER_BACKUP_MAX_AGE_HOURS', 25),
    ],
];
