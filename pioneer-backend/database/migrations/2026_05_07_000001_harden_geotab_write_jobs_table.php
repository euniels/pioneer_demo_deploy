<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('geotab_write_jobs', function (Blueprint $table): void {
            if (! Schema::hasColumn('geotab_write_jobs', 'created_by')) {
                $table->string('created_by', 120)->nullable()->after('idempotency_key');
            }
            if (! Schema::hasColumn('geotab_write_jobs', 'last_attempt_at')) {
                $table->timestamp('last_attempt_at')->nullable()->after('approved_at');
            }
            if (! Schema::hasColumn('geotab_write_jobs', 'next_attempt_at')) {
                $table->timestamp('next_attempt_at')->nullable()->index()->after('last_attempt_at');
            }
            if (! Schema::hasColumn('geotab_write_jobs', 'permanently_failed_at')) {
                $table->timestamp('permanently_failed_at')->nullable()->after('processed_at');
            }
            if (! Schema::hasColumn('geotab_write_jobs', 'audit_trail')) {
                $table->json('audit_trail')->nullable()->after('result');
            }
        });
    }

    public function down(): void
    {
        Schema::table('geotab_write_jobs', function (Blueprint $table): void {
            foreach ([
                'created_by',
                'last_attempt_at',
                'next_attempt_at',
                'permanently_failed_at',
                'audit_trail',
            ] as $column) {
                if (Schema::hasColumn('geotab_write_jobs', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }
};
