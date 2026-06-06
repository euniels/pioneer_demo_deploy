<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Str;

class GeotabWriteJob extends Model
{
    use HasFactory;

    protected $fillable = [
        'action',
        'entity_type',
        'local_type',
        'local_id',
        'geotab_id',
        'payload',
        'preview_payload',
        'status',
        'attempts',
        'max_attempts',
        'idempotency_key',
        'created_by',
        'approved_by',
        'approved_at',
        'last_attempt_at',
        'next_attempt_at',
        'processed_at',
        'permanently_failed_at',
        'last_error',
        'result',
        'audit_trail',
    ];

    protected $casts = [
        'payload' => 'array',
        'preview_payload' => 'array',
        'result' => 'array',
        'audit_trail' => 'array',
        'approved_at' => 'datetime',
        'last_attempt_at' => 'datetime',
        'next_attempt_at' => 'datetime',
        'processed_at' => 'datetime',
        'permanently_failed_at' => 'datetime',
    ];

    protected static function booted(): void
    {
        static::creating(function (GeotabWriteJob $job): void {
            if (trim((string) $job->idempotency_key) === '') {
                $job->idempotency_key = sha1(implode('|', [
                    $job->action,
                    $job->entity_type,
                    $job->local_type,
                    $job->local_id,
                    Str::random(16),
                ]));
            }
        });
    }
}
