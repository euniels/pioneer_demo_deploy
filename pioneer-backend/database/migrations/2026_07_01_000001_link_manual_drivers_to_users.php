<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('manual_drivers') || Schema::hasColumn('manual_drivers', 'user_id')) {
            return;
        }

        Schema::table('manual_drivers', function (Blueprint $table): void {
            $table->foreignId('user_id')
                ->nullable()
                ->after('id')
                ->constrained('users')
                ->nullOnDelete();
            $table->unique('user_id', 'manual_drivers_user_id_unique');
        });
    }

    public function down(): void
    {
        if (! Schema::hasTable('manual_drivers') || ! Schema::hasColumn('manual_drivers', 'user_id')) {
            return;
        }

        Schema::table('manual_drivers', function (Blueprint $table): void {
            $table->dropUnique('manual_drivers_user_id_unique');
            $table->dropConstrainedForeignId('user_id');
        });
    }
};
