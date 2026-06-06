<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        $this->indexIfPresent('gps_logs', ['trip_id', 'device_geotab_id', 'recorded_at'], 'gps_trip_device_recorded_idx');
        $this->indexIfPresent('gps_logs', ['trip_id', 'device_id', 'timestamp'], 'gps_trip_device_timestamp_idx');

        $this->indexIfPresent('trips', ['status'], 'trips_status_idx');
        $this->indexIfPresent('trips', ['departure_time'], 'trips_departure_idx');
        $this->indexIfPresent('trips', ['client_id'], 'trips_client_idx');
        $this->indexIfPresent('trips', ['driver_id'], 'trips_driver_idx');
        $this->indexIfPresent('trips', ['vehicle_id'], 'trips_vehicle_idx');

        $this->indexIfPresent('geotab_feed_rows', ['type_name', 'device_geotab_id', 'recorded_at'], 'feed_type_device_recorded_idx');
        $this->indexIfPresent('geotab_feed_rows', ['feed_type', 'device_id', 'recorded_timestamp'], 'feed_type_device_ts_idx');

        $this->indexIfPresent('notification_histories', ['user_id'], 'notifications_user_idx');
        $this->indexIfPresent('notification_histories', ['read_at', 'created_at'], 'notifications_read_created_idx');
        $this->indexIfPresent('notification_histories', ['created_at'], 'notifications_created_idx');

        $this->indexIfPresent('geotab_write_jobs', ['status', 'next_attempt_at'], 'write_jobs_status_next_idx');

        $this->indexIfPresent('invoices', ['trip_id'], 'invoices_trip_idx');
        $this->indexIfPresent('invoices', ['client_id'], 'invoices_client_idx');
        $this->indexIfPresent('invoices', ['status'], 'invoices_status_idx');
        $this->indexIfPresent('invoices', ['issued_date'], 'invoices_issued_date_idx');

        $this->indexIfPresent('billing_invoice_references', ['trip_id', 'status'], 'bill_refs_trip_status_idx');
        $this->indexIfPresent('billing_invoice_references', ['status', 'created_at'], 'bill_refs_status_created_idx');
    }

    public function down(): void
    {
        foreach ([
            'gps_logs' => [
                'gps_trip_device_recorded_idx' => ['trip_id', 'device_geotab_id', 'recorded_at'],
                'gps_trip_device_timestamp_idx' => ['trip_id', 'device_id', 'timestamp'],
            ],
            'trips' => [
                'trips_status_idx' => ['status'],
                'trips_departure_idx' => ['departure_time'],
                'trips_client_idx' => ['client_id'],
                'trips_driver_idx' => ['driver_id'],
                'trips_vehicle_idx' => ['vehicle_id'],
            ],
            'geotab_feed_rows' => [
                'feed_type_device_recorded_idx' => ['type_name', 'device_geotab_id', 'recorded_at'],
                'feed_type_device_ts_idx' => ['feed_type', 'device_id', 'recorded_timestamp'],
            ],
            'notification_histories' => [
                'notifications_user_idx' => ['user_id'],
                'notifications_read_created_idx' => ['read_at', 'created_at'],
                'notifications_created_idx' => ['created_at'],
            ],
            'geotab_write_jobs' => [
                'write_jobs_status_next_idx' => ['status', 'next_attempt_at'],
            ],
            'invoices' => [
                'invoices_trip_idx' => ['trip_id'],
                'invoices_client_idx' => ['client_id'],
                'invoices_status_idx' => ['status'],
                'invoices_issued_date_idx' => ['issued_date'],
            ],
            'billing_invoice_references' => [
                'bill_refs_trip_status_idx' => ['trip_id', 'status'],
                'bill_refs_status_created_idx' => ['status', 'created_at'],
            ],
        ] as $table => $indexes) {
            foreach ($indexes as $index => $columns) {
                $this->dropIndexIfPresent($table, $columns, $index);
            }
        }
    }

    /**
     * @param  array<int, string>  $columns
     */
    private function indexIfPresent(string $table, array $columns, string $name): void
    {
        if (! Schema::hasTable($table)) {
            return;
        }

        foreach ($columns as $column) {
            if (! Schema::hasColumn($table, $column)) {
                return;
            }
        }

        Schema::table($table, function (Blueprint $blueprint) use ($columns, $name): void {
            $blueprint->index($columns, $name);
        });
    }

    /**
     * @param  array<int, string>  $columns
     */
    private function dropIndexIfPresent(string $table, array $columns, string $name): void
    {
        if (! Schema::hasTable($table)) {
            return;
        }

        foreach ($columns as $column) {
            if (! Schema::hasColumn($table, $column)) {
                return;
            }
        }

        Schema::table($table, function (Blueprint $blueprint) use ($name): void {
            $blueprint->dropIndex($name);
        });
    }
};
