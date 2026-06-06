<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('geotab_feed_rows', function (Blueprint $table): void {
            $table->id();
            $table->string('type_name')->index();
            $table->string('geotab_id')->nullable()->index();
            $table->string('device_geotab_id')->nullable()->index();
            $table->string('trip_id')->nullable()->index();
            $table->string('diagnostic_geotab_id')->nullable()->index();
            $table->string('diagnostic_alias')->nullable()->index();
            $table->string('feed_cursor')->nullable()->index();
            $table->timestamp('recorded_at')->nullable()->index();
            $table->string('payload_hash', 64)->unique();
            $table->json('payload');
            $table->timestamps();

            $table->index(['type_name', 'recorded_at']);
            $table->index(['device_geotab_id', 'recorded_at']);
            $table->index(['trip_id', 'recorded_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('geotab_feed_rows');
    }
};
