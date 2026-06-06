<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class ManualDriver extends Model
{
    use HasFactory;

    protected $fillable = [
        'name',
        'license',
        'phone',
        'email',
        'status',
        'base_salary',
        'per_trip_bonus',
        'assigned_vehicle_geotab_id',
        'assigned_vehicle_plate',
        'sync_status',
        'sync_error',
        'pending_write_job_id',
        'geotab_snapshot',
        'meta',
    ];

    protected $casts = [
        'base_salary' => 'float',
        'per_trip_bonus' => 'float',
        'geotab_snapshot' => 'array',
        'meta' => 'array',
    ];
}
