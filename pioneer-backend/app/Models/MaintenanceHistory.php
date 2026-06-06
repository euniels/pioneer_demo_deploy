<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class MaintenanceHistory extends Model
{
    use HasFactory;

    protected $fillable = [
        'vehicle_geotab_id',
        'vehicle_plate',
        'type',
        'description',
        'status',
        'source',
        'recorded_at',
        'next_due_at',
        'odometer_km',
        'cost',
        'provider',
        'notes',
        'proof_file_name',
        'proof_file_type',
        'proof_file_data',
        'voided_at',
        'void_reason',
        'sync_status',
        'sync_error',
        'pending_write_job_id',
        'geotab_snapshot',
        'meta',
    ];

    protected $casts = [
        'recorded_at' => 'datetime',
        'next_due_at' => 'datetime',
        'odometer_km' => 'float',
        'cost' => 'float',
        'voided_at' => 'datetime',
        'geotab_snapshot' => 'array',
        'meta' => 'array',
    ];
}
