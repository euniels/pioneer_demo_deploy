<?php

namespace Database\Seeders;

use App\Models\User;
use Illuminate\Database\Console\Seeds\WithoutModelEvents;
use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\Hash;

class DatabaseSeeder extends Seeder
{
    use WithoutModelEvents;

    /**
     * Seed the application's database.
     */
    public function run(): void
    {
        $accounts = [
            [
                'name' => 'Super Administrator',
                'email' => 'admin@pioneerpath.local',
                'role' => 'super_administrator',
            ],
            [
                'name' => 'System Administrator',
                'email' => 'system@pioneerpath.local',
                'role' => 'system_administrator',
            ],
            [
                'name' => 'Fleet Manager',
                'email' => 'fleet@pioneerpath.local',
                'role' => 'fleet_manager',
            ],
            [
                'name' => 'Dispatch Coordinator',
                'email' => 'dispatcher@pioneerpath.local',
                'role' => 'dispatcher',
            ],
            [
                'name' => 'Accounting Staff',
                'email' => 'accounting@pioneerpath.local',
                'role' => 'accounting_staff',
            ],
            [
                'name' => 'Driver Account',
                'email' => 'driver@pioneerpath.local',
                'role' => 'driver',
            ],
        ];

        foreach ($accounts as $account) {
            User::query()->updateOrCreate(
                ['email' => $account['email']],
                [
                    'name' => $account['name'],
                    'password' => Hash::make('Pioneer@12345'),
                    'role' => $account['role'],
                    'status' => 'active',
                    'must_change_password' => false,
                    'failed_login_count' => 0,
                    'locked_until' => null,
                    'last_failed_login_at' => null,
                ],
            );
        }

        User::query()
            ->where('email', 'test@example.com')
            ->where('name', 'Test User')
            ->delete();

        $this->call(PioneerOperatingZonesSeeder::class);

        if (app()->environment('production')) {
            $this->command?->warn(
                'Replace the local admin password immediately after production setup.',
            );
        }
    }
}
