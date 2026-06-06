<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('fleet_trips', function (Blueprint $table): void {
            $table->id();
            $table->string('trip_id', 120)->unique();
            $table->string('status', 40)->default('pending')->index();
            $table->unsignedTinyInteger('workflow_phase_number')->default(1)->index();
            $table->string('customer')->index();
            $table->string('driver')->nullable()->index();
            $table->string('vehicle')->nullable()->index();
            $table->timestamp('scheduled_departure_at')->nullable()->index();
            $table->timestamp('cancelled_at')->nullable();
            $table->json('payload');
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('fleet_trips');
    }
};
