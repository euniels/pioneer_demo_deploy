<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('geotab_route_stop_snapshots', function (Blueprint $table): void {
            $table->id();
            $table->string('route_geotab_id')->nullable()->index();
            $table->string('device_geotab_id')->nullable()->index();
            $table->string('route_name')->nullable();
            $table->unsignedInteger('stop_sequence')->default(0);
            $table->string('zone_geotab_id')->nullable()->index();
            $table->string('stop_name')->nullable();
            $table->decimal('latitude', 10, 7)->nullable();
            $table->decimal('longitude', 10, 7)->nullable();
            $table->timestamp('eta_at')->nullable()->index();
            $table->timestamp('captured_at')->nullable()->index();
            $table->string('payload_hash', 64)->unique();
            $table->json('payload')->nullable();
            $table->timestamps();

            $table->index(['route_geotab_id', 'stop_sequence']);
            $table->index(['device_geotab_id', 'captured_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('geotab_route_stop_snapshots');
    }
};
