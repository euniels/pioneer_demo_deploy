<?php

use App\Models\GeotabWriteJob;
use App\Models\ManualDriver;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;

uses(RefreshDatabase::class);

it('adds validators to fleet json responses and honors if none match', function (): void {
    $first = $this->getJson('/api/fleet/maps/config')
        ->assertOk()
        ->assertHeader('ETag')
        ->assertHeader('Last-Modified');

    $etag = $first->headers->get('ETag');
    $cacheControl = (string) $first->headers->get('Cache-Control');
    expect($etag)->toBeString()->not->toBe('');
    expect($cacheControl)->toContain('private')->toContain('must-revalidate');

    $this->withHeaders(['If-None-Match' => $etag])
        ->getJson('/api/fleet/maps/config')
        ->assertStatus(304)
        ->assertHeader('ETag', $etag)
        ->assertSee('', false);
});

it('gzips larger fleet json responses when accepted by the client', function (): void {
    $response = $this->withHeader('Accept-Encoding', 'gzip')
        ->get('/api/fleet/geotab/health')
        ->assertOk()
        ->assertHeader('Content-Encoding', 'gzip')
        ->assertHeader('Vary');

    expect((string) $response->headers->get('Vary'))->toContain('Accept-Encoding');
    expect(strlen((string) $response->getContent()))->toBeGreaterThan(0);
});

it('does not apply fleet validators to non fleet endpoints', function (): void {
    $this->getJson('/api/health')
        ->assertOk()
        ->assertHeaderMissing('ETag');
});

it('paginates fleet list responses with bounded metadata', function (): void {
    ManualDriver::query()->where('name', 'like', 'Pagination Driver %')->delete();
    foreach (range(1, 30) as $index) {
        ManualDriver::query()->create([
            'name' => sprintf('Pagination Driver %02d', $index),
            'status' => 'available',
        ]);
    }

    $payload = $this->getJson('/api/fleet/drivers/manual?page=2&perPage=10')
        ->assertOk()
        ->json();

    expect($payload['data'])->toHaveCount(10)
        ->and(data_get($payload, 'meta.pagination.currentPage'))->toBe(2)
        ->and(data_get($payload, 'meta.pagination.perPage'))->toBe(10)
        ->and(data_get($payload, 'meta.pagination.total'))->toBeGreaterThanOrEqual(30)
        ->and(data_get($payload, 'meta.pagination.nextPage'))->toBe(3);
});

it('keeps manual driver list query count bounded as rows grow', function (): void {
    ManualDriver::query()->where('name', 'like', 'N Plus One Driver %')->delete();
    GeotabWriteJob::query()->where('local_type', 'manual_driver')->where('idempotency_key', 'like', 'nplus-%')->delete();

    foreach (range(1, 50) as $index) {
        $driver = ManualDriver::query()->create([
            'name' => sprintf('N Plus One Driver %02d', $index),
            'status' => 'available',
        ]);
        GeotabWriteJob::query()->create([
            'action' => 'driver.update',
            'entity_type' => 'User',
            'local_type' => 'manual_driver',
            'local_id' => (string) $driver->id,
            'idempotency_key' => 'nplus-'.$driver->id,
            'status' => $index % 2 === 0 ? 'succeeded' : 'pending_approval',
            'payload' => ['entity' => ['name' => $driver->name]],
        ]);
    }

    DB::flushQueryLog();
    DB::enableQueryLog();

    $this->getJson('/api/fleet/drivers/manual?perPage=50')
        ->assertOk();

    $queryCount = count(DB::getQueryLog());
    DB::disableQueryLog();

    expect($queryCount)->toBeLessThan(20);
});
