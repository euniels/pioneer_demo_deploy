<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class FleetClient extends Model
{
    use HasFactory;

    protected $fillable = [
        'company_name',
        'contact_person_name',
        'contact_number',
        'email',
        'billing_address',
        'delivery_address',
        'client_type',
        'payment_terms',
        'free_delivery_threshold',
        'erp_customer_id',
        'status',
        'deactivated_at',
        'audit_trail',
        'meta',
    ];

    protected function casts(): array
    {
        return [
            'free_delivery_threshold' => 'float',
            'deactivated_at' => 'datetime',
            'audit_trail' => 'array',
            'meta' => 'array',
        ];
    }
}
