<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('notification_histories', function (Blueprint $table): void {
            $table->id();
            $table->string('notification_id')->nullable()->index();
            $table->string('title');
            $table->text('message');
            $table->string('category')->default('system');
            $table->string('status')->default('sent');
            $table->string('audience')->default('internal');
            $table->json('payload')->nullable();
            $table->timestamp('delivered_at')->nullable()->index();
            $table->timestamp('read_at')->nullable()->index();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('notification_histories');
    }
};
