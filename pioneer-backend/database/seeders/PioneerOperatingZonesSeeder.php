<?php

namespace Database\Seeders;

use App\Models\FleetZone;
use Illuminate\Database\Seeder;

class PioneerOperatingZonesSeeder extends Seeder
{
    private const MOCK_NOTE = 'Mock zone - update with actual boundary before operational use.';

    public function run(): void
    {
        foreach ($this->operatingZones() as $zone) {
            FleetZone::query()->firstOrCreate(
                ['name' => $zone['name']],
                [
                    'zone_type' => $zone['zone_type'],
                    'boundary_points' => $zone['boundary_points'],
                    'center_latitude' => $zone['center_latitude'],
                    'center_longitude' => $zone['center_longitude'],
                    'client_name' => $zone['client_name'],
                    'status' => 'active',
                    'sync_status' => 'not_staged',
                    'meta' => [
                        'isMockZone' => true,
                        'createdFrom' => 'pioneer_operating_zones_seed',
                        'notes' => self::MOCK_NOTE,
                    ],
                ],
            );
        }
    }

    /**
     * Local reference boundaries for demonstrations and initial operations setup.
     * Staff must replace these polygons with surveyed/confirmed site boundaries.
     *
     * @return array<int, array<string, mixed>>
     */
    private function operatingZones(): array
    {
        return [
            [
                'name' => 'Pioneer Cabuyao Depot',
                'zone_type' => 'Depot',
                'client_name' => null,
                'center_latitude' => 14.2788,
                'center_longitude' => 121.1248,
                'boundary_points' => [
                    ['latitude' => 14.2769, 'longitude' => 121.1226],
                    ['latitude' => 14.2807, 'longitude' => 121.1226],
                    ['latitude' => 14.2807, 'longitude' => 121.1270],
                    ['latitude' => 14.2769, 'longitude' => 121.1270],
                ],
            ],
            [
                'name' => 'Araneta Center Delivery Zone',
                'zone_type' => 'Customer Site',
                'client_name' => 'Araneta',
                'center_latitude' => 14.6207,
                'center_longitude' => 121.0545,
                'boundary_points' => [
                    ['latitude' => 14.6179, 'longitude' => 121.0515],
                    ['latitude' => 14.6235, 'longitude' => 121.0515],
                    ['latitude' => 14.6235, 'longitude' => 121.0575],
                    ['latitude' => 14.6179, 'longitude' => 121.0575],
                ],
            ],
            [
                'name' => 'Camp Crame Delivery Zone',
                'zone_type' => 'Customer Site',
                'client_name' => 'Camp Crame',
                'center_latitude' => 14.6137,
                'center_longitude' => 121.0573,
                'boundary_points' => [
                    ['latitude' => 14.6109, 'longitude' => 121.0541],
                    ['latitude' => 14.6165, 'longitude' => 121.0541],
                    ['latitude' => 14.6165, 'longitude' => 121.0605],
                    ['latitude' => 14.6109, 'longitude' => 121.0605],
                ],
            ],
            [
                'name' => 'Isuzu Philippines Zone',
                'zone_type' => 'Customer Site',
                'client_name' => 'Isuzu Philippines',
                'center_latitude' => 14.2828,
                'center_longitude' => 121.0912,
                'boundary_points' => [
                    ['latitude' => 14.2802, 'longitude' => 121.0882],
                    ['latitude' => 14.2854, 'longitude' => 121.0882],
                    ['latitude' => 14.2854, 'longitude' => 121.0942],
                    ['latitude' => 14.2802, 'longitude' => 121.0942],
                ],
            ],
            [
                'name' => 'Davao Distribution Zone',
                'zone_type' => 'Customer Site',
                'client_name' => 'Davao',
                'center_latitude' => 7.0731,
                'center_longitude' => 125.6128,
                'boundary_points' => [
                    ['latitude' => 7.0694, 'longitude' => 125.6085],
                    ['latitude' => 7.0768, 'longitude' => 125.6085],
                    ['latitude' => 7.0768, 'longitude' => 125.6171],
                    ['latitude' => 7.0694, 'longitude' => 125.6171],
                ],
            ],
            [
                'name' => 'Empire Oil Service Zone',
                'zone_type' => 'Customer Site',
                'client_name' => 'Empire Oil',
                'center_latitude' => 14.5883,
                'center_longitude' => 120.9705,
                'boundary_points' => [
                    ['latitude' => 14.5855, 'longitude' => 120.9672],
                    ['latitude' => 14.5911, 'longitude' => 120.9672],
                    ['latitude' => 14.5911, 'longitude' => 120.9738],
                    ['latitude' => 14.5855, 'longitude' => 120.9738],
                ],
            ],
        ];
    }
}
