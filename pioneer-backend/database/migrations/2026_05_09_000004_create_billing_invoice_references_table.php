<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('billing_invoice_references', function (Blueprint $table): void {
            $table->id();
            $table->string('trip_id')->unique();
            $table->string('invoice_number')->nullable()->index();
            $table->string('erp_reference')->nullable();
            $table->string('po_number')->nullable();
            $table->string('dr_number')->nullable();
            $table->text('notes')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('billing_invoice_references');
    }
};
