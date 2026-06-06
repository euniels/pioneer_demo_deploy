<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('notification_histories', function (Blueprint $table): void {
            $table->unsignedInteger('delivery_attempts')->default(0)->after('delivered_at');
            $table->timestamp('last_delivery_at')->nullable()->after('delivery_attempts');
        });
    }

    public function down(): void
    {
        Schema::table('notification_histories', function (Blueprint $table): void {
            $table->dropColumn(['delivery_attempts', 'last_delivery_at']);
        });
    }
};
