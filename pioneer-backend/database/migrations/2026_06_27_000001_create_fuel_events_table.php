<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('fuel_events', function (Blueprint $table): void {
            $table->id();
            $table->string('vehicle_geotab_id')->nullable()->index();
            $table->string('vehicle_plate', 120)->nullable()->index();
            $table->string('driver_name')->nullable();
            $table->string('event_type', 60)->default('manual_record')->index();
            $table->string('source_type', 60)->default('manual')->index();
            $table->string('source_record_id')->nullable();
            $table->string('review_status', 60)->default('needs_review')->index();
            $table->string('confidence', 40)->default('manual');
            $table->string('station_name')->nullable();
            $table->string('station_provider')->nullable();
            $table->string('station_place_id')->nullable();
            $table->string('station_address')->nullable();
            $table->decimal('station_distance_meters', 10, 2)->nullable();
            $table->string('fuel_type', 40)->default('diesel');
            $table->dateTime('event_at')->nullable()->index();
            $table->decimal('latitude', 10, 7)->nullable();
            $table->decimal('longitude', 10, 7)->nullable();
            $table->decimal('liters', 12, 2)->nullable();
            $table->decimal('price_per_liter', 12, 2)->nullable();
            $table->decimal('total_cost', 14, 2)->nullable();
            $table->decimal('odometer_km', 12, 2)->nullable();
            $table->string('receipt_file_name')->nullable();
            $table->string('receipt_file_type', 120)->nullable();
            $table->longText('receipt_file_data')->nullable();
            $table->text('notes')->nullable();
            $table->text('rejection_reason')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();

            $table->unique(['source_type', 'source_record_id'], 'fuel_events_source_unique');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('fuel_events');
    }
};
