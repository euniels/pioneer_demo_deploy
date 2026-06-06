<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

class FleetRoute extends Model
{
    protected $fillable = [
        'name',
        'description',
        'assigned_vehicle_geotab_id',
        'assigned_vehicle_plate',
        'geotab_route_id',
        'status',
        'sync_status',
        'sync_error',
        'pending_write_job_id',
        'geotab_snapshot',
        'last_used_at',
        'deleted_at',
        'meta',
    ];

    protected function casts(): array
    {
        return [
            'last_used_at' => 'datetime',
            'deleted_at' => 'datetime',
            'geotab_snapshot' => 'array',
            'meta' => 'array',
        ];
    }

    public function stops(): HasMany
    {
        return $this->hasMany(FleetRouteStop::class)->orderBy('stop_sequence');
    }
}
