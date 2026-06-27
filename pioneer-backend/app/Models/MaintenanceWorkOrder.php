<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class MaintenanceWorkOrder extends Model
{
    use HasFactory;

    protected $fillable = [
        'vehicle_geotab_id',
        'vehicle_plate',
        'title',
        'description',
        'priority',
        'status',
        'source_type',
        'source_record_id',
        'source_summary',
        'assigned_to',
        'scheduled_at',
        'started_at',
        'completed_at',
        'verified_at',
        'estimated_cost',
        'actual_cost',
        'notes',
        'void_reason',
        'attachments',
        'audit_trail',
        'meta',
    ];

    protected $casts = [
        'scheduled_at' => 'datetime',
        'started_at' => 'datetime',
        'completed_at' => 'datetime',
        'verified_at' => 'datetime',
        'estimated_cost' => 'float',
        'actual_cost' => 'float',
        'attachments' => 'array',
        'audit_trail' => 'array',
        'meta' => 'array',
    ];
}
