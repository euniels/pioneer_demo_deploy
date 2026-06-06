<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class SystemSetting extends Model
{
    use HasFactory;

    protected $fillable = [
        'diesel_price_per_liter',
        'gasoline_price_per_liter',
        'price_last_updated',
        'price_source_label',
        'vat_rate_percent',
        'free_delivery_threshold',
        'base_delivery_charge_per_km',
        'fuel_surcharge_rate_percent',
        'diesel_price_source_label',
        'diesel_price_last_updated',
        'gasoline_price_source_label',
        'gasoline_price_last_updated',
        'geotab_server_url',
        'geotab_username',
        'geotab_default_group_id',
        'feed_seed_window_days',
        'feed_sync_interval_minutes',
        'gps_trail_max_points',
        'humidity_alert_min_percent',
        'humidity_alert_max_percent',
        'idle_time_alert_threshold_minutes',
        'maintenance_due_warning_days',
        'registration_expiry_warning_days',
        'license_expiry_warning_days',
        'gps_log_retention_days',
        'raw_geotab_feed_retention_days',
        'notification_history_retention_days',
        'audit_log_retention_days',
        'depot_latitude',
        'depot_longitude',
        'default_map_center_latitude',
        'default_map_center_longitude',
        'audit_log',
    ];

    protected $casts = [
        'diesel_price_per_liter' => 'decimal:2',
        'gasoline_price_per_liter' => 'decimal:2',
        'vat_rate_percent' => 'decimal:2',
        'price_last_updated' => 'datetime',
        'free_delivery_threshold' => 'decimal:2',
        'base_delivery_charge_per_km' => 'decimal:2',
        'fuel_surcharge_rate_percent' => 'decimal:2',
        'diesel_price_last_updated' => 'datetime',
        'gasoline_price_last_updated' => 'datetime',
        'feed_seed_window_days' => 'integer',
        'feed_sync_interval_minutes' => 'integer',
        'gps_trail_max_points' => 'integer',
        'humidity_alert_min_percent' => 'decimal:2',
        'humidity_alert_max_percent' => 'decimal:2',
        'idle_time_alert_threshold_minutes' => 'integer',
        'maintenance_due_warning_days' => 'integer',
        'registration_expiry_warning_days' => 'integer',
        'license_expiry_warning_days' => 'integer',
        'gps_log_retention_days' => 'integer',
        'raw_geotab_feed_retention_days' => 'integer',
        'notification_history_retention_days' => 'integer',
        'audit_log_retention_days' => 'integer',
        'depot_latitude' => 'decimal:7',
        'depot_longitude' => 'decimal:7',
        'default_map_center_latitude' => 'decimal:7',
        'default_map_center_longitude' => 'decimal:7',
        'audit_log' => 'array',
    ];
}
