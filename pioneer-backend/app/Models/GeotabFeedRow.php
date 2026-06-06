<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class GeotabFeedRow extends Model
{
    protected $fillable = [
        'type_name',
        'geotab_id',
        'device_geotab_id',
        'trip_id',
        'diagnostic_geotab_id',
        'diagnostic_alias',
        'feed_cursor',
        'recorded_at',
        'payload_hash',
        'payload',
    ];

    protected function casts(): array
    {
        return [
            'payload' => 'array',
            'recorded_at' => 'datetime',
        ];
    }
}
