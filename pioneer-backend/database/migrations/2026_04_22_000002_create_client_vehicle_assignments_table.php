<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('client_vehicle_assignments', function (Blueprint $table): void {
            $table->id();
            $table->string('client_name');
            $table->string('client_email')->nullable();
            $table->string('client_phone')->nullable();
            $table->string('vehicle_geotab_id')->nullable()->index();
            $table->string('vehicle_plate')->nullable();
            $table->string('trip_id')->nullable()->index();
            $table->string('status')->default('active');
            $table->text('notes')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('client_vehicle_assignments');
    }
};
