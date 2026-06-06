<?php

namespace App\Services;

use App\Models\BillingInvoiceReference;
use App\Models\GeotabFeedCheckpoint;
use App\Models\GeotabWriteJob;
use App\Models\GpsLog;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Schema;

class PioneerIntegrityCheckService
{
    /**
     * @return array<string, mixed>
     */
    public function check(): array
    {
        $tripIndex = $this->tripIndex();
        $findings = [
            'orphanedInvoices' => $this->orphanedInvoices($tripIndex['ids']),
            'orphanedGpsLogs' => $this->orphanedGpsLogs($tripIndex['ids']),
            'staleWriteBackJobs' => $this->staleWriteBackJobs(),
            'activeTripsWithoutRecentGps' => $this->activeTripsWithoutRecentGps($tripIndex['active']),
        ];

        $counts = array_map(fn (array $rows): int => count($rows), $findings);
        $total = array_sum($counts);

        return [
            'ok' => $total === 0,
            'checkedAt' => now()->toIso8601String(),
            'feedSeeded' => $this->geotabLogFeedSeeded(),
            'tripCount' => count($tripIndex['ids']),
            'counts' => $counts,
            'findings' => $findings,
        ];
    }

    /**
     * @param  array<string, mixed>  $result
     */
    public function logResult(array $result): void
    {
        $context = [
            'ok' => $result['ok'] ?? false,
            'checkedAt' => $result['checkedAt'] ?? null,
            'feedSeeded' => $result['feedSeeded'] ?? false,
            'tripCount' => $result['tripCount'] ?? 0,
            'counts' => $result['counts'] ?? [],
        ];

        if (($result['ok'] ?? false) === true) {
            Log::channel('integrity')->info('pioneerpath.integrity_check.ok', $context);

            return;
        }

        Log::channel('integrity')->warning('pioneerpath.integrity_check.findings', [
            ...$context,
            'findings' => $result['findings'] ?? [],
        ]);
    }

    /**
     * @return array{ids: array<int, string>, active: array<int, array<string, mixed>>}
     */
    private function tripIndex(): array
    {
        $trips = [];

        foreach (['geotab_fleet_snapshot_v4_fresh', 'geotab_fleet_snapshot_v4_stale'] as $key) {
            $snapshot = Cache::get($key, []);
            if (is_array($snapshot) && is_array($snapshot['trips'] ?? null)) {
                $trips = [...$trips, ...$snapshot['trips']];
            }
        }

        $workflow = Cache::get('geotab_workflow_state_v1', []);
        if (is_array($workflow)) {
            foreach (['customTrips', 'tripOverrides'] as $bucket) {
                foreach ((array) ($workflow[$bucket] ?? []) as $tripId => $trip) {
                    if (is_array($trip)) {
                        $trips[] = ['tripId' => (string) ($trip['tripId'] ?? $tripId), ...$trip];
                    }
                }
            }
        }

        if (Schema::hasTable('trips')) {
            $rows = DB::table('trips')->select('*')->get();
            foreach ($rows as $row) {
                $array = (array) $row;
                $trips[] = [
                    'tripId' => (string) ($array['trip_id'] ?? $array['id'] ?? ''),
                    'status' => $array['status'] ?? '',
                    'deviceGeotabId' => $array['device_geotab_id'] ?? $array['vehicle_id'] ?? null,
                ];
            }
        }

        $ids = [];
        $active = [];
        $activeStatuses = ['active', 'dispatched', 'in progress', 'in transit', 'on trip'];

        foreach ($trips as $trip) {
            if (! is_array($trip)) {
                continue;
            }

            $tripId = trim((string) ($trip['tripId'] ?? $trip['geotabId'] ?? ''));
            if ($tripId === '') {
                continue;
            }

            $ids[$tripId] = true;
            $status = strtolower(trim((string) ($trip['status'] ?? '')));
            if (in_array($status, $activeStatuses, true)) {
                $active[$tripId] = $trip;
            }
        }

        return [
            'ids' => array_keys($ids),
            'active' => array_values($active),
        ];
    }

    /**
     * @param  array<int, string>  $validTripIds
     * @return array<int, array<string, mixed>>
     */
    private function orphanedInvoices(array $validTripIds): array
    {
        $rows = [];
        if (Schema::hasTable('billing_invoice_references')) {
            $query = BillingInvoiceReference::query();
            if ($validTripIds !== []) {
                $query->whereNotIn('trip_id', $validTripIds);
            }
            $rows = [
                ...$rows,
                ...$query->limit(25)->get(['id', 'trip_id', 'status', 'updated_at'])
                    ->map(fn (BillingInvoiceReference $invoice): array => [
                        'table' => 'billing_invoice_references',
                        'id' => $invoice->id,
                        'tripId' => $invoice->trip_id,
                        'status' => $invoice->status,
                        'updatedAt' => $invoice->updated_at?->toIso8601String(),
                    ])
                    ->all(),
            ];
        }

        if (Schema::hasTable('invoices') && Schema::hasColumn('invoices', 'trip_id')) {
            $query = DB::table('invoices');
            if ($validTripIds !== []) {
                $query->whereNotIn('trip_id', $validTripIds);
            }
            foreach ($query->limit(25)->get(['id', 'trip_id', 'status', 'updated_at']) as $invoice) {
                $rows[] = [
                    'table' => 'invoices',
                    'id' => $invoice->id,
                    'tripId' => $invoice->trip_id,
                    'status' => $invoice->status ?? null,
                    'updatedAt' => $invoice->updated_at ?? null,
                ];
            }
        }

        return $rows;
    }

    /**
     * @param  array<int, string>  $validTripIds
     * @return array<int, array<string, mixed>>
     */
    private function orphanedGpsLogs(array $validTripIds): array
    {
        if (! Schema::hasTable('gps_logs')) {
            return [];
        }

        $query = GpsLog::query()
            ->where(function ($builder) use ($validTripIds): void {
                $builder->whereNull('trip_id')
                    ->orWhere('trip_id', '');

                if ($validTripIds !== []) {
                    $builder->orWhereNotIn('trip_id', $validTripIds);
                }
            })
            ->when(Schema::hasColumn('gps_logs', 'association_status'), function ($query): void {
                $query->whereNotIn('association_status', ['pending_trip_match', 'needs_review']);
            })
            ->orderByDesc('recorded_at')
            ->limit(25);

        return $query->get(['id', 'trip_id', 'geotab_log_id', 'device_geotab_id', 'recorded_at', 'meta'])
            ->map(fn (GpsLog $log): array => [
                'id' => $log->id,
                'logId' => $log->geotab_log_id,
                'tripId' => $log->trip_id,
                'deviceGeotabId' => $log->device_geotab_id,
                'recordedAt' => $log->recorded_at?->toIso8601String(),
                'source' => is_array($log->meta) ? ($log->meta['source'] ?? null) : null,
            ])
            ->all();
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function staleWriteBackJobs(): array
    {
        if (! Schema::hasTable('geotab_write_jobs')) {
            return [];
        }

        return GeotabWriteJob::query()
            ->whereIn('status', ['pending', 'pending_approval', 'approved'])
            ->where('created_at', '<', now()->subDay())
            ->orderBy('created_at')
            ->limit(25)
            ->get(['id', 'action', 'local_type', 'local_id', 'status', 'created_at', 'last_error'])
            ->map(fn (GeotabWriteJob $job): array => [
                'id' => $job->id,
                'action' => $job->action,
                'localType' => $job->local_type,
                'localId' => $job->local_id,
                'status' => $job->status,
                'createdAt' => $job->created_at?->toIso8601String(),
                'lastError' => $job->last_error,
            ])
            ->all();
    }

    /**
     * @param  array<int, array<string, mixed>>  $activeTrips
     * @return array<int, array<string, mixed>>
     */
    private function activeTripsWithoutRecentGps(array $activeTrips): array
    {
        if (! $this->geotabLogFeedSeeded() || ! Schema::hasTable('gps_logs')) {
            return [];
        }

        $cutoff = now()->subHours(4);
        $findings = [];
        foreach ($activeTrips as $trip) {
            $tripId = trim((string) ($trip['tripId'] ?? $trip['geotabId'] ?? ''));
            if ($tripId === '') {
                continue;
            }

            $hasRecentLog = GpsLog::query()
                ->where('trip_id', $tripId)
                ->where('recorded_at', '>=', $cutoff)
                ->exists();
            if ($hasRecentLog) {
                continue;
            }

            $findings[] = [
                'tripId' => $tripId,
                'status' => $trip['status'] ?? null,
                'vehicle' => $trip['vehicle'] ?? null,
                'deviceGeotabId' => $trip['deviceGeotabId'] ?? null,
            ];
        }

        return array_slice($findings, 0, 25);
    }

    private function geotabLogFeedSeeded(): bool
    {
        if (! Schema::hasTable('geotab_feed_checkpoints')) {
            return false;
        }

        return GeotabFeedCheckpoint::query()
            ->where('type_name', 'LogRecord')
            ->where(function ($query): void {
                $query->whereNotNull('seeded_at')->orWhereNotNull('last_success_at');
            })
            ->exists();
    }
}
