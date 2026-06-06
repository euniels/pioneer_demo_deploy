<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class GeotabRouteStopSnapshot extends Model
{
    protected $fillable = [
        'route_geotab_id',
        'device_geotab_id',
        'route_name',
        'stop_sequence',
        'zone_geotab_id',
        'stop_name',
        'latitude',
        'longitude',
        'eta_at',
        'captured_at',
        'payload_hash',
        'payload',
    ];

    protected function casts(): array
    {
        return [
            'latitude' => 'float',
            'longitude' => 'float',
            'eta_at' => 'datetime',
            'captured_at' => 'datetime',
            'payload' => 'array',
        ];
    }
}
