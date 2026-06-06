<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('gps_logs', function (Blueprint $table): void {
            if (! Schema::hasColumn('gps_logs', 'association_status')) {
                $table->string('association_status', 40)
                    ->default('matched')
                    ->after('meta')
                    ->index();
            }

            if (! Schema::hasColumn('gps_logs', 'association_review_reason')) {
                $table->string('association_review_reason', 255)
                    ->nullable()
                    ->after('association_status');
            }
        });
    }

    public function down(): void
    {
        Schema::table('gps_logs', function (Blueprint $table): void {
            if (Schema::hasColumn('gps_logs', 'association_review_reason')) {
                $table->dropColumn('association_review_reason');
            }

            if (Schema::hasColumn('gps_logs', 'association_status')) {
                $table->dropIndex(['association_status']);
                $table->dropColumn('association_status');
            }
        });
    }
};
