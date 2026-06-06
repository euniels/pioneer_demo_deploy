<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class GpsLog extends Model
{
    use HasFactory;

    protected $fillable = [
        'trip_id',
        'geotab_log_id',
        'device_geotab_id',
        'latitude',
        'longitude',
        'speed',
        'bearing',
        'recorded_at',
        'meta',
        'association_status',
        'association_review_reason',
    ];

    protected $casts = [
        'latitude' => 'float',
        'longitude' => 'float',
        'speed' => 'float',
        'bearing' => 'float',
        'recorded_at' => 'datetime',
        'meta' => 'array',
    ];
}
