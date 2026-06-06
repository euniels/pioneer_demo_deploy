<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('maintenance_histories', function (Blueprint $table): void {
            if (! Schema::hasColumn('maintenance_histories', 'odometer_km')) {
                $table->decimal('odometer_km', 12, 2)->nullable()->after('next_due_at');
            }
            if (! Schema::hasColumn('maintenance_histories', 'source')) {
                $table->string('source', 40)->default('manual')->index()->after('status');
            }
            if (! Schema::hasColumn('maintenance_histories', 'proof_file_name')) {
                $table->string('proof_file_name')->nullable()->after('notes');
            }
            if (! Schema::hasColumn('maintenance_histories', 'proof_file_type')) {
                $table->string('proof_file_type', 80)->nullable()->after('proof_file_name');
            }
            if (! Schema::hasColumn('maintenance_histories', 'proof_file_data')) {
                $table->longText('proof_file_data')->nullable()->after('proof_file_type');
            }
            if (! Schema::hasColumn('maintenance_histories', 'voided_at')) {
                $table->timestamp('voided_at')->nullable()->index()->after('proof_file_data');
            }
            if (! Schema::hasColumn('maintenance_histories', 'void_reason')) {
                $table->text('void_reason')->nullable()->after('voided_at');
            }
            if (! Schema::hasColumn('maintenance_histories', 'sync_status')) {
                $table->string('sync_status', 60)->default('not_staged')->index()->after('void_reason');
            }
            if (! Schema::hasColumn('maintenance_histories', 'sync_error')) {
                $table->text('sync_error')->nullable()->after('sync_status');
            }
            if (! Schema::hasColumn('maintenance_histories', 'pending_write_job_id')) {
                $table->unsignedBigInteger('pending_write_job_id')->nullable()->index()->after('sync_error');
            }
        });
    }

    public function down(): void
    {
        Schema::table('maintenance_histories', function (Blueprint $table): void {
            foreach ([
                'pending_write_job_id',
                'sync_error',
                'sync_status',
                'void_reason',
                'voided_at',
                'proof_file_data',
                'proof_file_type',
                'proof_file_name',
                'source',
                'odometer_km',
            ] as $column) {
                if (Schema::hasColumn('maintenance_histories', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }
};
