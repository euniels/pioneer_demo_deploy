<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class ClientVehicleAssignment extends Model
{
    use HasFactory;

    protected $fillable = [
        'client_name',
        'client_email',
        'client_phone',
        'vehicle_geotab_id',
        'vehicle_plate',
        'trip_id',
        'status',
        'notes',
        'meta',
    ];

    protected $casts = [
        'meta' => 'array',
    ];
}
