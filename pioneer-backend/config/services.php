<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Third Party Services
    |--------------------------------------------------------------------------
    |
    | This file is for storing the credentials for third party services such
    | as Mailgun, Postmark, AWS and more. This file provides the de facto
    | location for this type of information, allowing packages to have
    | a conventional file to locate the various service credentials.
    |
    */

    'postmark' => [
        'key' => env('POSTMARK_API_KEY'),
    ],

    'resend' => [
        'key' => env('RESEND_API_KEY'),
    ],

    'ses' => [
        'key' => env('AWS_ACCESS_KEY_ID'),
        'secret' => env('AWS_SECRET_ACCESS_KEY'),
        'region' => env('AWS_DEFAULT_REGION', 'us-east-1'),
    ],

    'slack' => [
        'notifications' => [
            'bot_user_oauth_token' => env('SLACK_BOT_USER_OAUTH_TOKEN'),
            'channel' => env('SLACK_BOT_USER_DEFAULT_CHANNEL'),
        ],
    ],

    'web_push' => [
        'public_key' => env('VAPID_PUBLIC_KEY', ''),
        'private_key' => env('VAPID_PRIVATE_KEY', ''),
        'subject' => env('VAPID_SUBJECT', 'mailto:admin@yourcompany.com'),
    ],

    'firebase' => [
        'credentials' => env('FIREBASE_CREDENTIALS', ''),
        'project_id' => env('FIREBASE_PROJECT_ID', ''),
    ],

    'google_maps' => [
        'browser_key' => env('GOOGLE_MAPS_BROWSER_KEY', env('GOOGLE_MAPS_API_KEY', '')),
        'server_key' => env('GOOGLE_MAPS_SERVER_KEY', env('GOOGLE_MAPS_API_KEY', '')),
        'depot_latitude' => env('GOOGLE_MAPS_DEPOT_LATITUDE'),
        'depot_longitude' => env('GOOGLE_MAPS_DEPOT_LONGITUDE'),
        'enrichment_enabled' => filter_var(env('GOOGLE_MAPS_ENRICHMENT_ENABLED', false), FILTER_VALIDATE_BOOLEAN),
    ],

    'geotab' => [
        'default_group_id' => env('GEOTAB_DEFAULT_GROUP_ID', ''),
    ],

];
