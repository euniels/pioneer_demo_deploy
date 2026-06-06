<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('geotab_write_jobs', function (Blueprint $table): void {
            $table->id();
            $table->string('action', 80)->index();
            $table->string('entity_type', 80)->index();
            $table->string('local_type', 80)->nullable()->index();
            $table->string('local_id', 120)->nullable()->index();
            $table->string('geotab_id', 120)->nullable()->index();
            $table->json('payload');
            $table->string('status', 40)->default('pending_approval')->index();
            $table->unsignedInteger('attempts')->default(0);
            $table->unsignedInteger('max_attempts')->default(3);
            $table->string('idempotency_key', 160)->unique();
            $table->string('approved_by', 120)->nullable();
            $table->timestamp('approved_at')->nullable();
            $table->timestamp('processed_at')->nullable();
            $table->text('last_error')->nullable();
            $table->json('result')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('geotab_write_jobs');
    }
};
