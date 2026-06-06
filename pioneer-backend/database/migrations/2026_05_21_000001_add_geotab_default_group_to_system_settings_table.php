<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('system_settings') || Schema::hasColumn('system_settings', 'geotab_default_group_id')) {
            return;
        }

        Schema::table('system_settings', function (Blueprint $table): void {
            $table->string('geotab_default_group_id')->nullable()->after('geotab_username');
        });
    }

    public function down(): void
    {
        if (! Schema::hasTable('system_settings') || ! Schema::hasColumn('system_settings', 'geotab_default_group_id')) {
            return;
        }

        Schema::table('system_settings', function (Blueprint $table): void {
            $table->dropColumn('geotab_default_group_id');
        });
    }
};
