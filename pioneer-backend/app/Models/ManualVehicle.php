<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class ManualVehicle extends Model
{
    use HasFactory;

    protected $fillable = [
        'plate_number',
        'vehicle_type',
        'make_model',
        'year',
        'chassis_number',
        'vin',
        'fuel_type',
        'fuel_capacity_liters',
        'cargo_capacity_kg',
        'geotab_device_id',
        'registration_expiry_date',
        'insurance_expiry_date',
        'status',
        'sync_status',
        'sync_error',
        'pending_write_job_id',
        'geotab_snapshot',
        'deactivated_at',
        'meta',
    ];

    protected function casts(): array
    {
        return [
            'year' => 'integer',
            'fuel_capacity_liters' => 'float',
            'cargo_capacity_kg' => 'float',
            'registration_expiry_date' => 'date',
            'insurance_expiry_date' => 'date',
            'deactivated_at' => 'datetime',
            'geotab_snapshot' => 'array',
            'meta' => 'array',
        ];
    }
}
