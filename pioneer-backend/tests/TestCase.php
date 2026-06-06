<?php

namespace Tests;

use App\Services\GeotabService;
use Carbon\CarbonInterface;
use Illuminate\Foundation\Testing\TestCase as BaseTestCase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;

abstract class TestCase extends BaseTestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Cache::flush();
        Http::preventStrayRequests();

        $this->app->bind(GeotabService::class, fn (): GeotabService => new class extends GeotabService
        {
            public function isConfigured(): bool
            {
                return true;
            }

            public function authenticate(): string
            {
                return 'test-geotab-session';
            }

            public function call(string $method, array $params = []): mixed
            {
                return $method === 'Add' ? 'test-geotab-id' : [];
            }

            public function getEntities(
                string $typeName,
                array $search = [],
                ?int $resultsLimit = null,
                array $extraParams = [],
            ): array {
                return [];
            }

            public function addEntity(string $typeName, array $entity): string
            {
                return 'test-geotab-id';
            }

            public function setEntity(string $typeName, array $entity): void {}

            public function removeEntity(string $typeName, array $entity): void {}

            public function getAddresses(array $coordinates, bool $movingAddresses = false, bool $hosAddresses = false): array
            {
                return [];
            }

            public function getGpsTrail(
                string $deviceId,
                int $limit = 500,
                ?CarbonInterface $from = null,
                ?CarbonInterface $to = null,
            ): array {
                return [];
            }

            public function getFeed(
                string $typeName,
                ?string $fromVersion = null,
                array $search = [],
                ?int $resultsLimit = null,
                ?CarbonInterface $fromDate = null,
                ?array $propertySelector = null,
            ): array {
                return [
                    'data' => [],
                    'toVersion' => $fromVersion ?: 'test-feed-version',
                ];
            }

            public function resolveDiagnostics(array $lookupMap): array
            {
                return [];
            }
        });
    }
}
