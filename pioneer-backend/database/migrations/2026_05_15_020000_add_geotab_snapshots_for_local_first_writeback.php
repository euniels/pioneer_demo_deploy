<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        foreach ([
            'manual_drivers',
            'manual_vehicles',
            'fleet_routes',
            'fleet_zones',
            'maintenance_histories',
        ] as $tableName) {
            if (! Schema::hasTable($tableName) || Schema::hasColumn($tableName, 'geotab_snapshot')) {
                continue;
            }

            Schema::table($tableName, function (Blueprint $table) use ($tableName): void {
                if ($tableName === 'manual_drivers') {
                    if (! Schema::hasColumn($tableName, 'sync_status')) {
                        $table->string('sync_status', 60)->default('not_staged')->index()->after('assigned_vehicle_plate');
                    }
                    if (! Schema::hasColumn($tableName, 'sync_error')) {
                        $table->text('sync_error')->nullable()->after('sync_status');
                    }
                    if (! Schema::hasColumn($tableName, 'pending_write_job_id')) {
                        $table->unsignedBigInteger('pending_write_job_id')->nullable()->index()->after('sync_error');
                    }
                }

                $table->json('geotab_snapshot')->nullable()->after(
                    Schema::hasColumn($tableName, 'pending_write_job_id')
                        ? 'pending_write_job_id'
                        : 'meta'
                );
            });
        }
    }

    public function down(): void
    {
        foreach ([
            'maintenance_histories',
            'fleet_zones',
            'fleet_routes',
            'manual_vehicles',
            'manual_drivers',
        ] as $tableName) {
            if (! Schema::hasTable($tableName)) {
                continue;
            }

            Schema::table($tableName, function (Blueprint $table) use ($tableName): void {
                foreach (['geotab_snapshot'] as $column) {
                    if (Schema::hasColumn($tableName, $column)) {
                        $table->dropColumn($column);
                    }
                }

                if ($tableName === 'manual_drivers') {
                    foreach (['pending_write_job_id', 'sync_error', 'sync_status'] as $column) {
                        if (Schema::hasColumn($tableName, $column)) {
                            $table->dropColumn($column);
                        }
                    }
                }
            });
        }
    }
};
