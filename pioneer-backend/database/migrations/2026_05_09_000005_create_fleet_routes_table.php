<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('fleet_routes', function (Blueprint $table): void {
            $table->id();
            $table->string('name')->index();
            $table->text('description')->nullable();
            $table->string('assigned_vehicle_geotab_id')->nullable()->index();
            $table->string('assigned_vehicle_plate')->nullable()->index();
            $table->string('geotab_route_id')->nullable()->index();
            $table->string('status', 40)->default('active')->index();
            $table->string('sync_status', 40)->default('not_staged')->index();
            $table->text('sync_error')->nullable();
            $table->unsignedBigInteger('pending_write_job_id')->nullable()->index();
            $table->timestamp('last_used_at')->nullable()->index();
            $table->timestamp('deleted_at')->nullable()->index();
            $table->json('meta')->nullable();
            $table->timestamps();
        });

        Schema::create('fleet_route_stops', function (Blueprint $table): void {
            $table->id();
            $table->foreignId('fleet_route_id')->constrained('fleet_routes')->cascadeOnDelete();
            $table->unsignedInteger('stop_sequence')->index();
            $table->string('stop_name');
            $table->string('geotab_zone_id')->nullable()->index();
            $table->decimal('latitude', 10, 7);
            $table->decimal('longitude', 10, 7);
            $table->unsignedInteger('estimated_stop_duration_minutes')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();

            $table->unique(['fleet_route_id', 'stop_sequence']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('fleet_route_stops');
        Schema::dropIfExists('fleet_routes');
    }
};
