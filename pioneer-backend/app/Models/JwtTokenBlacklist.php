<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class JwtTokenBlacklist extends Model
{
    protected $table = 'jwt_token_blacklist';

    protected $fillable = [
        'jti',
        'user_id',
        'expires_at',
        'reason',
    ];

    protected function casts(): array
    {
        return [
            'expires_at' => 'datetime',
        ];
    }
}
