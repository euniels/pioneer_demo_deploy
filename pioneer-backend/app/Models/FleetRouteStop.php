<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class FleetRouteStop extends Model
{
    protected $fillable = [
        'fleet_route_id',
        'stop_sequence',
        'stop_name',
        'geotab_zone_id',
        'latitude',
        'longitude',
        'estimated_stop_duration_minutes',
        'meta',
    ];

    protected function casts(): array
    {
        return [
            'latitude' => 'float',
            'longitude' => 'float',
            'meta' => 'array',
        ];
    }

    public function route(): BelongsTo
    {
        return $this->belongsTo(FleetRoute::class, 'fleet_route_id');
    }
}
