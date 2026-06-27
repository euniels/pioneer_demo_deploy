<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class FuelEvent extends Model
{
    protected $fillable = [
        'vehicle_geotab_id',
        'vehicle_plate',
        'driver_name',
        'event_type',
        'source_type',
        'source_record_id',
        'review_status',
        'confidence',
        'station_name',
        'station_provider',
        'station_place_id',
        'station_address',
        'station_distance_meters',
        'fuel_type',
        'event_at',
        'latitude',
        'longitude',
        'liters',
        'price_per_liter',
        'total_cost',
        'odometer_km',
        'receipt_file_name',
        'receipt_file_type',
        'receipt_file_data',
        'notes',
        'rejection_reason',
        'meta',
    ];

    protected $casts = [
        'event_at' => 'datetime',
        'latitude' => 'float',
        'longitude' => 'float',
        'liters' => 'float',
        'price_per_liter' => 'float',
        'total_cost' => 'float',
        'odometer_km' => 'float',
        'station_distance_meters' => 'float',
        'meta' => 'array',
    ];
}
