<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class GeotabFeedCheckpoint extends Model
{
    protected $fillable = [
        'type_name',
        'cursor',
        'seeded_at',
        'seed_from',
        'last_success_at',
        'last_error_at',
        'last_error',
        'last_row_count',
        'consecutive_failures',
        'meta',
        'synced_at',
    ];

    protected function casts(): array
    {
        return [
            'seeded_at' => 'datetime',
            'seed_from' => 'datetime',
            'last_success_at' => 'datetime',
            'last_error_at' => 'datetime',
            'last_row_count' => 'integer',
            'consecutive_failures' => 'integer',
            'meta' => 'array',
            'synced_at' => 'datetime',
        ];
    }
}
