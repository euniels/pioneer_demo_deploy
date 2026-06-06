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

    'backups' => [
        'path' => env('PIONEER_BACKUP_PATH', storage_path('app/backups')),
        'patterns' => array_values(array_filter(array_map(
            'trim',
            explode(',', env('PIONEER_BACKUP_PATTERNS', '*.sql,*.sql.gz,*.dump,*.backup,*.bak'))
        ))),
        'max_age_hours' => (int) env('PIONEER_BACKUP_MAX_AGE_HOURS', 25),
    ],
];
