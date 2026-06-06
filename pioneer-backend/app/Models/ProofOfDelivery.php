<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class ProofOfDelivery extends Model
{
    use HasFactory;

    protected $fillable = [
        'trip_id',
        'tracking_token',
        'recipient_name',
        'notes',
        'signature_data_url',
        'status',
        'delivered_at',
        'attachments',
        'meta',
    ];

    protected $casts = [
        'delivered_at' => 'datetime',
        'attachments' => 'array',
        'meta' => 'array',
    ];
}
