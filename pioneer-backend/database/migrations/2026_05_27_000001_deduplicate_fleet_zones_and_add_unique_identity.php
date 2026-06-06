<?php

use App\Models\FleetZone;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('fleet_zones')) {
            return;
        }

        if (! Schema::hasColumn('fleet_zones', 'dedupe_key')) {
            Schema::table('fleet_zones', function (Blueprint $table): void {
                $table->string('dedupe_key', 64)->nullable()->after('boundary_points');
            });
        }

        $keptByIdentity = [];
        $activeZones = DB::table('fleet_zones')
            ->where('status', '!=', 'deleted')
            ->whereNull('deleted_at')
            ->orderByDesc('updated_at')
            ->orderByDesc('id')
            ->get();

        foreach ($activeZones as $zone) {
            $points = json_decode((string) $zone->boundary_points, true);
            $key = FleetZone::dedupeKey((string) $zone->name, is_array($points) ? $points : []);
            $keeper = $keptByIdentity[$key] ?? null;
            if ($keeper === null) {
                DB::table('fleet_zones')->where('id', $zone->id)->update(['dedupe_key' => $key]);
                $keptByIdentity[$key] = $zone;

                continue;
            }

            $keeperUpdates = [];
            if (empty($keeper->geotab_zone_id) && ! empty($zone->geotab_zone_id)) {
                $keeperUpdates['geotab_zone_id'] = $zone->geotab_zone_id;
                $keeperUpdates['geotab_snapshot'] = $zone->geotab_snapshot;
                $keeperUpdates['sync_status'] = $zone->sync_status;
                $keeper->geotab_zone_id = $zone->geotab_zone_id;
            }
            if ($keeperUpdates !== []) {
                DB::table('fleet_zones')->where('id', $keeper->id)->update($keeperUpdates);
            }

            if (Schema::hasTable('geotab_write_jobs')) {
                DB::table('geotab_write_jobs')
                    ->where('local_type', 'fleet_zone')
                    ->where('local_id', (string) $zone->id)
                    ->update(['local_id' => (string) $keeper->id]);
            }

            Log::warning('Removed duplicate active fleet zone during deduplication migration.', [
                'removedZoneId' => $zone->id,
                'retainedZoneId' => $keeper->id,
                'zoneName' => $zone->name,
            ]);
            DB::table('fleet_zones')->where('id', $zone->id)->delete();
        }

        DB::table('fleet_zones')
            ->where(function ($query): void {
                $query->where('status', 'deleted')->orWhereNotNull('deleted_at');
            })
            ->update(['dedupe_key' => null]);

        Schema::table('fleet_zones', function (Blueprint $table): void {
            $table->unique('dedupe_key', 'fleet_zones_active_identity_unique');
        });
    }

    public function down(): void
    {
        if (! Schema::hasTable('fleet_zones') || ! Schema::hasColumn('fleet_zones', 'dedupe_key')) {
            return;
        }

        Schema::table('fleet_zones', function (Blueprint $table): void {
            $table->dropUnique('fleet_zones_active_identity_unique');
            $table->dropColumn('dedupe_key');
        });
    }
};
