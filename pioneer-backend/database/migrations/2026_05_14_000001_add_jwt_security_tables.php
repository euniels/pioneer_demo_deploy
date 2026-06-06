<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table): void {
            if (! Schema::hasColumn('users', 'failed_login_count')) {
                $table->unsignedInteger('failed_login_count')->default(0)->after('must_change_password');
            }
            if (! Schema::hasColumn('users', 'locked_until')) {
                $table->timestamp('locked_until')->nullable()->after('failed_login_count');
            }
            if (! Schema::hasColumn('users', 'last_failed_login_at')) {
                $table->timestamp('last_failed_login_at')->nullable()->after('locked_until');
            }
        });

        Schema::create('jwt_refresh_tokens', function (Blueprint $table): void {
            $table->id();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->string('token_hash', 128)->unique();
            $table->string('platform', 30)->default('web')->index();
            $table->timestamp('expires_at')->index();
            $table->timestamp('revoked_at')->nullable()->index();
            $table->string('created_ip', 64)->nullable();
            $table->string('user_agent', 500)->nullable();
            $table->timestamps();
        });

        Schema::create('jwt_token_blacklist', function (Blueprint $table): void {
            $table->id();
            $table->string('jti', 80)->unique();
            $table->foreignId('user_id')->nullable()->constrained()->nullOnDelete();
            $table->timestamp('expires_at')->index();
            $table->string('reason', 120)->nullable();
            $table->timestamps();
        });

        Schema::create('login_attempt_logs', function (Blueprint $table): void {
            $table->id();
            $table->string('email', 255)->nullable()->index();
            $table->foreignId('user_id')->nullable()->constrained()->nullOnDelete();
            $table->string('ip_address', 64)->index();
            $table->boolean('successful')->default(false)->index();
            $table->string('failure_reason', 120)->nullable();
            $table->timestamp('attempted_at')->index();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('login_attempt_logs');
        Schema::dropIfExists('jwt_token_blacklist');
        Schema::dropIfExists('jwt_refresh_tokens');

        Schema::table('users', function (Blueprint $table): void {
            foreach (['last_failed_login_at', 'locked_until', 'failed_login_count'] as $column) {
                if (Schema::hasColumn('users', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }
};
