<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class NotificationPreference extends Model
{
    use HasFactory;

    protected $fillable = [
        'scope',
        'scope_key',
        'browser_enabled',
        'email_enabled',
        'trip_alerts',
        'maintenance_alerts',
        'billing_alerts',
        'system_alerts',
        'quiet_hours',
        'meta',
    ];

    protected $casts = [
        'browser_enabled' => 'boolean',
        'email_enabled' => 'boolean',
        'trip_alerts' => 'boolean',
        'maintenance_alerts' => 'boolean',
        'billing_alerts' => 'boolean',
        'system_alerts' => 'boolean',
        'quiet_hours' => 'array',
        'meta' => 'array',
    ];
}
