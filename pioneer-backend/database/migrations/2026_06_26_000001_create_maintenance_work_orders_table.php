<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('maintenance_work_orders')) {
            return;
        }

        Schema::create('maintenance_work_orders', function (Blueprint $table): void {
            $table->id();
            $table->string('vehicle_geotab_id')->nullable()->index();
            $table->string('vehicle_plate')->nullable()->index();
            $table->string('title');
            $table->text('description');
            $table->string('priority', 40)->default('medium')->index();
            $table->string('status', 40)->default('open')->index();
            $table->string('source_type', 80)->default('manual')->index();
            $table->string('source_record_id')->nullable()->index();
            $table->text('source_summary')->nullable();
            $table->string('assigned_to')->nullable()->index();
            $table->timestamp('scheduled_at')->nullable()->index();
            $table->timestamp('started_at')->nullable();
            $table->timestamp('completed_at')->nullable();
            $table->timestamp('verified_at')->nullable();
            $table->decimal('estimated_cost', 12, 2)->nullable();
            $table->decimal('actual_cost', 12, 2)->nullable();
            $table->text('notes')->nullable();
            $table->text('void_reason')->nullable();
            $table->json('attachments')->nullable();
            $table->json('audit_trail')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();

            $table->unique(['source_type', 'source_record_id'], 'maintenance_work_orders_source_unique');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('maintenance_work_orders');
    }
};
