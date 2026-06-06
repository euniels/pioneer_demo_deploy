<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class BillingInvoiceReference extends Model
{
    use HasFactory;

    protected $fillable = [
        'trip_id',
        'invoice_number',
        'erp_reference',
        'po_number',
        'dr_number',
        'notes',
        'status',
        'manual_invoice',
        'override_reason',
        'line_items',
        'overrides',
        'status_history',
        'voided_at',
        'void_reason',
        'meta',
    ];

    protected $casts = [
        'manual_invoice' => 'boolean',
        'line_items' => 'array',
        'overrides' => 'array',
        'status_history' => 'array',
        'voided_at' => 'datetime',
        'meta' => 'array',
    ];
}
