<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class PushSubscription extends Model
{
    use HasFactory;

    protected $fillable = [
        'endpoint_hash',
        'endpoint',
        'platform',
        'keys',
        'meta',
        'last_seen_at',
    ];

    protected $casts = [
        'keys' => 'array',
        'meta' => 'array',
        'last_seen_at' => 'datetime',
    ];
}
