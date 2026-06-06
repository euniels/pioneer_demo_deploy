<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('billing_invoice_references', function (Blueprint $table): void {
            if (! Schema::hasColumn('billing_invoice_references', 'status')) {
                $table->string('status')->default('issued')->index()->after('notes');
            }
            if (! Schema::hasColumn('billing_invoice_references', 'manual_invoice')) {
                $table->boolean('manual_invoice')->default(false)->after('status');
            }
            if (! Schema::hasColumn('billing_invoice_references', 'override_reason')) {
                $table->text('override_reason')->nullable()->after('manual_invoice');
            }
            if (! Schema::hasColumn('billing_invoice_references', 'line_items')) {
                $table->json('line_items')->nullable()->after('override_reason');
            }
            if (! Schema::hasColumn('billing_invoice_references', 'overrides')) {
                $table->json('overrides')->nullable()->after('line_items');
            }
            if (! Schema::hasColumn('billing_invoice_references', 'status_history')) {
                $table->json('status_history')->nullable()->after('overrides');
            }
            if (! Schema::hasColumn('billing_invoice_references', 'voided_at')) {
                $table->timestamp('voided_at')->nullable()->after('status_history');
            }
            if (! Schema::hasColumn('billing_invoice_references', 'void_reason')) {
                $table->text('void_reason')->nullable()->after('voided_at');
            }
        });
    }

    public function down(): void
    {
        Schema::table('billing_invoice_references', function (Blueprint $table): void {
            foreach ([
                'void_reason',
                'voided_at',
                'status_history',
                'overrides',
                'line_items',
                'override_reason',
                'manual_invoice',
                'status',
            ] as $column) {
                if (Schema::hasColumn('billing_invoice_references', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }
};
