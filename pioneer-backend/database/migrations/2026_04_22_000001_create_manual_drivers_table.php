<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('manual_drivers', function (Blueprint $table): void {
            $table->id();
            $table->string('name');
            $table->string('license')->nullable();
            $table->string('phone')->nullable();
            $table->string('email')->nullable();
            $table->string('status')->default('available');
            $table->decimal('base_salary', 12, 2)->nullable();
            $table->decimal('per_trip_bonus', 12, 2)->nullable();
            $table->string('assigned_vehicle_geotab_id')->nullable()->index();
            $table->string('assigned_vehicle_plate')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('manual_drivers');
    }
};
