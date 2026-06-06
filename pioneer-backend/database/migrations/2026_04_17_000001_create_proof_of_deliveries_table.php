<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('proof_of_deliveries', function (Blueprint $table) {
            $table->id();
            $table->string('trip_id')->unique();
            $table->string('tracking_token')->unique();
            $table->string('recipient_name')->nullable();
            $table->longText('notes')->nullable();
            $table->longText('signature_data_url')->nullable();
            $table->string('status')->default('submitted');
            $table->timestamp('delivered_at')->nullable();
            $table->json('attachments')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('proof_of_deliveries');
    }
};
