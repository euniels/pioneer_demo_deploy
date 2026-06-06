<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('maintenance_histories', function (Blueprint $table): void {
            $table->id();
            $table->string('vehicle_geotab_id')->nullable()->index();
            $table->string('vehicle_plate')->nullable()->index();
            $table->string('type');
            $table->text('description');
            $table->string('status')->default('recorded');
            $table->timestamp('recorded_at')->nullable()->index();
            $table->timestamp('next_due_at')->nullable()->index();
            $table->decimal('cost', 12, 2)->nullable();
            $table->string('provider')->nullable();
            $table->text('notes')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('maintenance_histories');
    }
};
