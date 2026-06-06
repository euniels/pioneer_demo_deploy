<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table): void {
            if (! Schema::hasColumn('users', 'role')) {
                $table->string('role')->default('system_administrator')->after('password')->index();
            }
            if (! Schema::hasColumn('users', 'phone')) {
                $table->string('phone')->nullable()->after('role');
            }
            if (! Schema::hasColumn('users', 'status')) {
                $table->string('status')->default('active')->after('phone')->index();
            }
            if (! Schema::hasColumn('users', 'must_change_password')) {
                $table->boolean('must_change_password')->default(true)->after('status');
            }
            if (! Schema::hasColumn('users', 'last_login_at')) {
                $table->timestamp('last_login_at')->nullable()->after('must_change_password');
            }
            if (! Schema::hasColumn('users', 'deactivated_at')) {
                $table->timestamp('deactivated_at')->nullable()->after('last_login_at');
            }
            if (! Schema::hasColumn('users', 'activity_log')) {
                $table->json('activity_log')->nullable()->after('deactivated_at');
            }
            if (! Schema::hasColumn('users', 'created_by')) {
                $table->string('created_by')->nullable()->after('activity_log');
            }
        });
    }

    public function down(): void
    {
        Schema::table('users', function (Blueprint $table): void {
            foreach ([
                'created_by',
                'activity_log',
                'deactivated_at',
                'last_login_at',
                'must_change_password',
                'status',
                'phone',
                'role',
            ] as $column) {
                if (Schema::hasColumn('users', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }
};
