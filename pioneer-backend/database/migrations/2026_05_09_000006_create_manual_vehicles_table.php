<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('manual_vehicles', function (Blueprint $table): void {
            $table->id();
            $table->string('plate_number', 80)->unique();
            $table->string('vehicle_type', 120)->index();
            $table->string('make_model')->nullable();
            $table->unsignedSmallInteger('year')->nullable();
            $table->string('chassis_number', 160)->nullable();
            $table->string('vin', 160)->nullable()->index();
            $table->string('fuel_type', 40)->index();
            $table->decimal('fuel_capacity_liters', 10, 2)->nullable();
            $table->decimal('cargo_capacity_kg', 12, 2);
            $table->string('geotab_device_id', 120)->nullable()->index();
            $table->date('registration_expiry_date')->index();
            $table->date('insurance_expiry_date')->nullable()->index();
            $table->string('status', 60)->default('active')->index();
            $table->string('sync_status', 60)->default('not_staged')->index();
            $table->text('sync_error')->nullable();
            $table->unsignedBigInteger('pending_write_job_id')->nullable()->index();
            $table->timestamp('deactivated_at')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();

            $table->index(['status', 'vehicle_type']);
            $table->index(['status', 'fuel_type']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('manual_vehicles');
    }
};
