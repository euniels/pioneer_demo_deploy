<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class FleetTrip extends Model
{
    protected $fillable = [
        'trip_id',
        'status',
        'workflow_phase_number',
        'customer',
        'driver',
        'vehicle',
        'scheduled_departure_at',
        'cancelled_at',
        'payload',
    ];

    protected function casts(): array
    {
        return [
            'workflow_phase_number' => 'integer',
            'scheduled_departure_at' => 'datetime',
            'cancelled_at' => 'datetime',
            'payload' => 'array',
        ];
    }
}
