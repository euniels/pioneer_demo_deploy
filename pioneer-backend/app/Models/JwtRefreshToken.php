<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class JwtRefreshToken extends Model
{
    protected $fillable = [
        'user_id',
        'token_hash',
        'platform',
        'expires_at',
        'revoked_at',
        'created_ip',
        'user_agent',
    ];

    protected function casts(): array
    {
        return [
            'expires_at' => 'datetime',
            'revoked_at' => 'datetime',
        ];
    }
}
