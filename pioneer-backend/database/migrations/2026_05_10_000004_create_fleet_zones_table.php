<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('fleet_zones', function (Blueprint $table): void {
            $table->id();
            $table->string('name')->index();
            $table->string('zone_type', 80)->default('Other')->index();
            $table->json('boundary_points');
            $table->decimal('center_latitude', 10, 7)->nullable();
            $table->decimal('center_longitude', 10, 7)->nullable();
            $table->foreignId('fleet_client_id')->nullable()->constrained('fleet_clients')->nullOnDelete();
            $table->string('client_name')->nullable()->index();
            $table->string('geotab_zone_id')->nullable()->index();
            $table->string('status', 40)->default('active')->index();
            $table->string('sync_status', 40)->default('pending_approval')->index();
            $table->text('sync_error')->nullable();
            $table->unsignedBigInteger('pending_write_job_id')->nullable()->index();
            $table->timestamp('deleted_at')->nullable()->index();
            $table->json('meta')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('fleet_zones');
    }
};
