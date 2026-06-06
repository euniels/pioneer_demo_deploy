<?php

namespace App\Models;

use App\Services\RealtimeFleetEventBroadcaster;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

class NotificationHistory extends Model
{
    use HasFactory;

    protected $fillable = [
        'notification_id',
        'title',
        'message',
        'category',
        'status',
        'audience',
        'payload',
        'delivered_at',
        'delivery_attempts',
        'last_delivery_at',
        'read_at',
    ];

    protected $casts = [
        'payload' => 'array',
        'delivered_at' => 'datetime',
        'last_delivery_at' => 'datetime',
        'read_at' => 'datetime',
    ];

    protected static function booted(): void
    {
        static::created(function (NotificationHistory $notification): void {
            app(RealtimeFleetEventBroadcaster::class)->publishNotification($notification);
        });

        static::updated(function (NotificationHistory $notification): void {
            if ($notification->wasChanged(['read_at', 'title', 'message', 'category', 'payload'])) {
                app(RealtimeFleetEventBroadcaster::class)->publishNotification($notification);
            }
        });
    }
}
