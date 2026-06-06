<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('system_settings', function (Blueprint $table): void {
            $this->decimal($table, 'free_delivery_threshold', 12, 2, 100000);
            $this->decimal($table, 'base_delivery_charge_per_km', 10, 2, 65);
            $this->decimal($table, 'fuel_surcharge_rate_percent', 5, 2, 15);
            $this->string($table, 'diesel_price_source_label');
            $this->timestamp($table, 'diesel_price_last_updated');
            $this->string($table, 'gasoline_price_source_label');
            $this->timestamp($table, 'gasoline_price_last_updated');
            $this->string($table, 'geotab_server_url', 255, config('services.geotab.server', 'https://my.geotab.com'));
            $this->string($table, 'geotab_username', 255, env('GEOTAB_USERNAME', ''));
            $this->unsignedInteger($table, 'feed_seed_window_days', 30);
            $this->unsignedInteger($table, 'feed_sync_interval_minutes', 2);
            $this->unsignedInteger($table, 'gps_trail_max_points', 200);
            $this->decimal($table, 'humidity_alert_min_percent', 5, 2, 0);
            $this->decimal($table, 'humidity_alert_max_percent', 5, 2, 75);
            $this->unsignedInteger($table, 'idle_time_alert_threshold_minutes', 30);
            $this->unsignedInteger($table, 'maintenance_due_warning_days', 14);
            $this->unsignedInteger($table, 'registration_expiry_warning_days', 30);
            $this->unsignedInteger($table, 'license_expiry_warning_days', 30);
            $this->decimal($table, 'depot_latitude', 10, 7);
            $this->decimal($table, 'depot_longitude', 10, 7);
            $this->decimal($table, 'default_map_center_latitude', 10, 7, 14.5995);
            $this->decimal($table, 'default_map_center_longitude', 10, 7, 120.9842);
            $this->json($table, 'audit_log');
        });
    }

    public function down(): void
    {
        Schema::table('system_settings', function (Blueprint $table): void {
            foreach ([
                'free_delivery_threshold',
                'base_delivery_charge_per_km',
                'fuel_surcharge_rate_percent',
                'diesel_price_source_label',
                'diesel_price_last_updated',
                'gasoline_price_source_label',
                'gasoline_price_last_updated',
                'geotab_server_url',
                'geotab_username',
                'feed_seed_window_days',
                'feed_sync_interval_minutes',
                'gps_trail_max_points',
                'humidity_alert_min_percent',
                'humidity_alert_max_percent',
                'idle_time_alert_threshold_minutes',
                'maintenance_due_warning_days',
                'registration_expiry_warning_days',
                'license_expiry_warning_days',
                'depot_latitude',
                'depot_longitude',
                'default_map_center_latitude',
                'default_map_center_longitude',
                'audit_log',
            ] as $column) {
                if (Schema::hasColumn('system_settings', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }

    private function decimal(Blueprint $table, string $column, int $precision, int $scale, float|int|null $default = null): void
    {
        if (! Schema::hasColumn('system_settings', $column)) {
            $definition = $table->decimal($column, $precision, $scale)->nullable();
            if ($default !== null) {
                $definition->default($default);
            }
        }
    }

    private function string(Blueprint $table, string $column, int $length = 255, ?string $default = null): void
    {
        if (! Schema::hasColumn('system_settings', $column)) {
            $definition = $table->string($column, $length)->nullable();
            if ($default !== null && $default !== '') {
                $definition->default($default);
            }
        }
    }

    private function timestamp(Blueprint $table, string $column): void
    {
        if (! Schema::hasColumn('system_settings', $column)) {
            $table->timestamp($column)->nullable();
        }
    }

    private function unsignedInteger(Blueprint $table, string $column, int $default): void
    {
        if (! Schema::hasColumn('system_settings', $column)) {
            $table->unsignedInteger($column)->default($default);
        }
    }

    private function json(Blueprint $table, string $column): void
    {
        if (! Schema::hasColumn('system_settings', $column)) {
            $table->json($column)->nullable();
        }
    }
};
