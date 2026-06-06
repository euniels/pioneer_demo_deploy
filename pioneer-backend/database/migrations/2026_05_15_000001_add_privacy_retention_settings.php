<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('system_settings', function (Blueprint $table): void {
            $this->unsignedInteger($table, 'gps_log_retention_days', 90);
            $this->unsignedInteger($table, 'raw_geotab_feed_retention_days', 30);
            $this->unsignedInteger($table, 'notification_history_retention_days', 90);
            $this->unsignedInteger($table, 'audit_log_retention_days', 365);
        });
    }

    public function down(): void
    {
        Schema::table('system_settings', function (Blueprint $table): void {
            foreach ([
                'gps_log_retention_days',
                'raw_geotab_feed_retention_days',
                'notification_history_retention_days',
                'audit_log_retention_days',
            ] as $column) {
                if (Schema::hasColumn('system_settings', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }

    private function unsignedInteger(Blueprint $table, string $column, int $default): void
    {
        if (! Schema::hasColumn('system_settings', $column)) {
            $table->unsignedInteger($column)->default($default);
        }
    }
};
