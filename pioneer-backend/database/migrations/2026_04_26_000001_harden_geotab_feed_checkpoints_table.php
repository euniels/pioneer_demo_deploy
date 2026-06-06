<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('geotab_feed_checkpoints', function (Blueprint $table): void {
            $table->timestamp('seeded_at')->nullable()->after('cursor')->index();
            $table->timestamp('seed_from')->nullable()->after('seeded_at');
            $table->timestamp('last_success_at')->nullable()->after('seed_from')->index();
            $table->timestamp('last_error_at')->nullable()->after('last_success_at');
            $table->text('last_error')->nullable()->after('last_error_at');
            $table->unsignedInteger('last_row_count')->default(0)->after('last_error');
            $table->unsignedInteger('consecutive_failures')->default(0)->after('last_row_count');
        });
    }

    public function down(): void
    {
        Schema::table('geotab_feed_checkpoints', function (Blueprint $table): void {
            $table->dropColumn([
                'seeded_at',
                'seed_from',
                'last_success_at',
                'last_error_at',
                'last_error',
                'last_row_count',
                'consecutive_failures',
            ]);
        });
    }
};
