<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('gps_logs', function (Blueprint $table): void {
            $table->id();
            $table->string('trip_id')->nullable()->index();
            $table->string('geotab_log_id')->nullable()->unique();
            $table->string('device_geotab_id')->index();
            $table->decimal('latitude', 10, 7);
            $table->decimal('longitude', 10, 7);
            $table->decimal('speed', 8, 2)->default(0);
            $table->decimal('bearing', 8, 2)->nullable();
            $table->timestamp('recorded_at')->index();
            $table->json('meta')->nullable();
            $table->timestamps();

            $table->index(['trip_id', 'recorded_at']);
            $table->index(['device_geotab_id', 'recorded_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('gps_logs');
    }
};
