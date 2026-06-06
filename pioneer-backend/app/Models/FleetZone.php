<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Schema;

class FleetZone extends Model
{
    protected $fillable = [
        'name',
        'zone_type',
        'boundary_points',
        'center_latitude',
        'center_longitude',
        'fleet_client_id',
        'client_name',
        'geotab_zone_id',
        'status',
        'sync_status',
        'sync_error',
        'pending_write_job_id',
        'geotab_snapshot',
        'dedupe_key',
        'deleted_at',
        'meta',
    ];

    protected static function booted(): void
    {
        static::saving(function (FleetZone $zone): void {
            if (! Schema::hasColumn($zone->getTable(), 'dedupe_key')) {
                return;
            }

            $zone->dedupe_key = $zone->status === 'deleted' || $zone->deleted_at !== null
                ? null
                : self::dedupeKey((string) $zone->name, (array) $zone->boundary_points);
        });
    }

    /**
     * Zones with the same display name and polygon are one local managed zone,
     * regardless of which polygon vertex was selected first.
     */
    public static function dedupeKey(string $name, array $points): string
    {
        $coordinates = array_values(array_filter(array_map(
            static function (mixed $point): ?string {
                if (! is_array($point)) {
                    return null;
                }

                $latitude = $point['latitude'] ?? $point['y'] ?? null;
                $longitude = $point['longitude'] ?? $point['x'] ?? null;
                if (! is_numeric($latitude) || ! is_numeric($longitude)) {
                    return null;
                }

                return sprintf('%.7F,%.7F', (float) $latitude, (float) $longitude);
            },
            $points,
        )));

        if (count($coordinates) > 1 && $coordinates[0] === $coordinates[array_key_last($coordinates)]) {
            array_pop($coordinates);
        }

        $canonicalPolygon = self::canonicalPolygon($coordinates);

        return hash('sha256', mb_strtolower(trim($name)).'|'.$canonicalPolygon);
    }

    /**
     * @param  array<int, string>  $coordinates
     */
    private static function canonicalPolygon(array $coordinates): string
    {
        if ($coordinates === []) {
            return '';
        }

        $candidates = [];
        foreach ([$coordinates, array_reverse($coordinates)] as $direction) {
            for ($index = 0; $index < count($direction); $index++) {
                $rotated = [...array_slice($direction, $index), ...array_slice($direction, 0, $index)];
                $candidates[] = implode(';', $rotated);
            }
        }

        sort($candidates, SORT_STRING);

        return $candidates[0];
    }

    protected function casts(): array
    {
        return [
            'boundary_points' => 'array',
            'center_latitude' => 'float',
            'center_longitude' => 'float',
            'deleted_at' => 'datetime',
            'geotab_snapshot' => 'array',
            'meta' => 'array',
        ];
    }

    public function client(): BelongsTo
    {
        return $this->belongsTo(FleetClient::class, 'fleet_client_id');
    }
}
