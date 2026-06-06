<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('geotab_feed_checkpoints', function (Blueprint $table) {
            $table->id();
            $table->string('type_name')->unique();
            $table->string('cursor')->nullable();
            $table->json('meta')->nullable();
            $table->timestamp('synced_at')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('geotab_feed_checkpoints');
    }
};
