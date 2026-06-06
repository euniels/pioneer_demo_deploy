<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('fleet_clients', function (Blueprint $table): void {
            $table->id();
            $table->string('company_name')->unique();
            $table->string('contact_person_name');
            $table->string('contact_number', 120);
            $table->string('email')->nullable();
            $table->text('billing_address');
            $table->text('delivery_address')->nullable();
            $table->string('client_type', 40)->default('regular')->index();
            $table->string('payment_terms', 40)->default('cod')->index();
            $table->decimal('free_delivery_threshold', 12, 2)->default(100000);
            $table->string('erp_customer_id', 120)->nullable()->index();
            $table->string('status', 40)->default('active')->index();
            $table->timestamp('deactivated_at')->nullable();
            $table->json('audit_trail')->nullable();
            $table->json('meta')->nullable();
            $table->timestamps();

            $table->index(['status', 'company_name']);
            $table->index(['client_type', 'payment_terms']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('fleet_clients');
    }
};
