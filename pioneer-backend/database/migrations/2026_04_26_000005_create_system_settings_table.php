<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('system_settings', function (Blueprint $table): void {
            $table->id();
            $table->decimal('diesel_price_per_liter', 10, 2)->default(0);
            $table->decimal('gasoline_price_per_liter', 10, 2)->default(0);
            $table->timestamp('price_last_updated')->nullable();
            $table->string('price_source_label')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('system_settings');
    }
};
