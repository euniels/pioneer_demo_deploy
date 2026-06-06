<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('geotab_write_jobs', function (Blueprint $table): void {
            if (! Schema::hasColumn('geotab_write_jobs', 'preview_payload')) {
                $table->json('preview_payload')->nullable()->after('payload');
            }
        });
    }

    public function down(): void
    {
        Schema::table('geotab_write_jobs', function (Blueprint $table): void {
            if (Schema::hasColumn('geotab_write_jobs', 'preview_payload')) {
                $table->dropColumn('preview_payload');
            }
        });
    }
};
