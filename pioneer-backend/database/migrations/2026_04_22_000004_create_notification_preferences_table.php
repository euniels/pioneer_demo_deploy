<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('notification_preferences', function (Blueprint $table): void {
            $table->id();
            $table->string('scope')->default('global');
            $table->string('scope_key')->default('default');
            $table->boolean('browser_enabled')->default(true);
            $table->boolean('email_enabled')->default(false);
            $table->boolean('trip_alerts')->default(true);
            $table->boolean('maintenance_alerts')->default(true);
            $table->boolean('billing_alerts')->default(true);
            $table->boolean('system_alerts')->default(true);
            $table->json('quiet_hours')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();
            $table->unique(['scope', 'scope_key']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('notification_preferences');
    }
};
