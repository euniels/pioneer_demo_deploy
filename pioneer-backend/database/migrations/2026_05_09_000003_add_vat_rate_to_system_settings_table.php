<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('system_settings') || Schema::hasColumn('system_settings', 'vat_rate_percent')) {
            return;
        }

        Schema::table('system_settings', function (Blueprint $table): void {
            $table->decimal('vat_rate_percent', 5, 2)->default(12.00);
        });
    }

    public function down(): void
    {
        if (! Schema::hasTable('system_settings') || ! Schema::hasColumn('system_settings', 'vat_rate_percent')) {
            return;
        }

        Schema::table('system_settings', function (Blueprint $table): void {
            $table->dropColumn('vat_rate_percent');
        });
    }
};
