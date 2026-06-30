<?php

namespace App\Services;

use Illuminate\Http\Client\PendingRequest;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

class GoogleMapsEnrichmentService
{
    private const CONNECT_TIMEOUT_SECONDS = 5;

    private const READ_TIMEOUT_SECONDS = 10;

    public function isConfigured(): bool
    {
        return $this->serverKey() !== '';
    }

    /**
     * @param  array<int, array<string, mixed>>  $points
     * @return array{points: array<int, array<string, mixed>>, snapped: bool, source: string, message: string}
     */
    public function snapCompletedTripTrail(string $tripId, array $points): array
    {
        $normalized = $this->validPoints($points);
        if (count($normalized) < 2) {
            return [
                'points' => $points,
                'snapped' => false,
                'source' => 'raw_gps',
                'message' => 'Insufficient GPS points for Roads API snapping.',
            ];
        }

        if (! $this->isConfigured()) {
            return [
                'points' => $points,
                'snapped' => false,
                'source' => 'raw_gps',
                'message' => 'Google Maps server key is not configured.',
            ];
        }

        $cacheKey = 'google_maps_roads_snap_v1_'.md5($tripId.'|'.json_encode($normalized));

        return Cache::remember($cacheKey, now()->addDays(7), function () use ($points, $normalized): array {
            try {
                $snapped = [];
                foreach (array_chunk($normalized, 100) as $chunk) {
                    $path = implode('|', array_map(
                        fn (array $point): string => $point['latitude'].','.$point['longitude'],
                        $chunk,
                    ));

                    $response = $this->httpClient()
                        ->get('https://roads.googleapis.com/v1/snapToRoads', [
                            'path' => $path,
                            'interpolate' => 'true',
                            'key' => $this->serverKey(),
                        ]);

                    if (! $response->successful()) {
                        throw new \RuntimeException('Roads API returned HTTP '.$response->status().'.');
                    }

                    foreach ((array) $response->json('snappedPoints', []) as $row) {
                        $latitude = data_get($row, 'location.latitude');
                        $longitude = data_get($row, 'location.longitude');
                        if (! is_numeric($latitude) || ! is_numeric($longitude)) {
                            continue;
                        }

                        $snapped[] = [
                            'latitude' => round((float) $latitude, 6),
                            'longitude' => round((float) $longitude, 6),
                            'source' => 'google_roads_snap_to_roads',
                            'placeId' => data_get($row, 'placeId'),
                        ];
                    }
                }

                if (count($snapped) < 2) {
                    return [
                        'points' => $points,
                        'snapped' => false,
                        'source' => 'raw_gps',
                        'message' => 'Roads API did not return enough snapped points.',
                    ];
                }

                return [
                    'points' => $snapped,
                    'snapped' => true,
                    'source' => 'google_roads_snap_to_roads',
                    'message' => 'Completed trip GPS trail snapped to Google Roads.',
                ];
            } catch (\Throwable $e) {
                $this->logFailure('roads.snap_to_roads', $e);

                return [
                    'points' => $points,
                    'snapped' => false,
                    'source' => 'raw_gps',
                    'message' => 'Roads API unavailable; using raw GPS route.',
                ];
            }
        });
    }

    /**
     * @param  array<string, mixed>  $origin
     * @param  array<string, mixed>  $destination
     * @return array<string, mixed>|null
     */
    public function distanceMatrixEta(string $tripId, array $origin, array $destination): ?array
    {
        $originPoint = $this->validPoint($origin);
        $destinationPoint = $this->validPoint($destination);
        if ($originPoint === null || $destinationPoint === null || ! $this->isConfigured()) {
            return null;
        }

        $cacheKey = 'google_maps_distance_matrix_v1_'.md5($tripId.'|'.json_encode([
            'origin' => $this->roundedPoint($originPoint, 4),
            'destination' => $this->roundedPoint($destinationPoint, 4),
        ]));

        return Cache::remember($cacheKey, now()->addMinutes(5), function () use ($originPoint, $destinationPoint): ?array {
            try {
                $response = $this->httpClient()
                    ->get('https://maps.googleapis.com/maps/api/distancematrix/json', [
                        'origins' => $originPoint['latitude'].','.$originPoint['longitude'],
                        'destinations' => $destinationPoint['latitude'].','.$destinationPoint['longitude'],
                        'mode' => 'driving',
                        'departure_time' => 'now',
                        'key' => $this->serverKey(),
                    ]);

                if (! $response->successful()) {
                    throw new \RuntimeException('Distance Matrix returned HTTP '.$response->status().'.');
                }

                $element = data_get($response->json(), 'rows.0.elements.0');
                if (! is_array($element) || ($element['status'] ?? '') !== 'OK') {
                    return null;
                }

                $duration = data_get($element, 'duration_in_traffic', data_get($element, 'duration'));
                $distance = data_get($element, 'distance');

                return [
                    'eta' => data_get($duration, 'text'),
                    'durationSeconds' => data_get($duration, 'value'),
                    'distanceText' => data_get($distance, 'text'),
                    'distanceMeters' => data_get($distance, 'value'),
                    'source' => 'google_distance_matrix',
                    'cachedForSeconds' => 300,
                ];
            } catch (\Throwable $e) {
                $this->logFailure('distance_matrix.eta', $e);

                return null;
            }
        });
    }

    /**
     * @param  array<string, mixed>  $coordinate
     * @return array<string, mixed>|null
     */
    public function currentWeather(array $coordinate): ?array
    {
        $point = $this->validPoint($coordinate);
        if ($point === null || ! $this->isConfigured()) {
            return null;
        }

        $cacheKey = 'google_weather_current_v1_'.md5(json_encode($this->roundedPoint($point, 3)));

        return Cache::remember($cacheKey, now()->addMinutes(20), function () use ($point): ?array {
            try {
                $response = $this->httpClient()
                    ->get('https://weather.googleapis.com/v1/currentConditions:lookup', [
                        'location.latitude' => $point['latitude'],
                        'location.longitude' => $point['longitude'],
                        'unitsSystem' => 'METRIC',
                        'languageCode' => 'en',
                        'key' => $this->serverKey(),
                    ]);

                if (! $response->successful()) {
                    throw new \RuntimeException('Weather API returned HTTP '.$response->status().'.');
                }

                $payload = $response->json();
                $temperature = data_get($payload, 'temperature.degrees');
                $feelsLike = data_get($payload, 'feelsLikeTemperature.degrees');
                $humidity = data_get($payload, 'relativeHumidity');
                $condition = trim((string) data_get($payload, 'weatherCondition.description.text', ''));

                if (! is_numeric($temperature) && ! is_numeric($humidity) && $condition === '') {
                    return null;
                }

                return [
                    'temperatureC' => is_numeric($temperature) ? round((float) $temperature, 1) : null,
                    'feelsLikeC' => is_numeric($feelsLike) ? round((float) $feelsLike, 1) : null,
                    'relativeHumidity' => is_numeric($humidity) ? round((float) $humidity, 1) : null,
                    'condition' => $condition !== '' ? $condition : null,
                    'isDaytime' => data_get($payload, 'isDaytime'),
                    'uvIndex' => data_get($payload, 'uvIndex'),
                    'precipitationProbability' => data_get($payload, 'precipitation.probability.percent'),
                    'source' => 'google_weather_current_conditions',
                    'updatedAt' => (string) (data_get($payload, 'currentTime') ?: now()->toIso8601String()),
                ];
            } catch (\Throwable $e) {
                $this->logFailure('weather.current_conditions', $e);

                return null;
            }
        });
    }

    /**
     * @param  array<string, mixed>  $origin
     * @param  array<string, mixed>  $destination
     * @return array<string, mixed>|null
     */
    public function trafficAwareRoute(string $cacheScope, array $origin, array $destination): ?array
    {
        $originPoint = $this->validPoint($origin);
        $destinationPoint = $this->validPoint($destination);
        if ($originPoint === null || $destinationPoint === null || ! $this->isConfigured()) {
            return null;
        }

        $cacheKey = 'google_routes_traffic_v1_'.md5($cacheScope.'|'.json_encode([
            'origin' => $this->roundedPoint($originPoint, 3),
            'destination' => $this->roundedPoint($destinationPoint, 3),
        ]));

        return Cache::remember($cacheKey, now()->addMinutes(3), function () use ($originPoint, $destinationPoint): ?array {
            try {
                $response = $this->httpClient()
                    ->withHeaders([
                        'X-Goog-Api-Key' => $this->serverKey(),
                        'X-Goog-FieldMask' => 'routes.duration,routes.staticDuration,routes.distanceMeters,routes.polyline.encodedPolyline,routes.travelAdvisory.speedReadingIntervals',
                    ])
                    ->post('https://routes.googleapis.com/directions/v2:computeRoutes', [
                        'origin' => $this->routesWaypoint($originPoint),
                        'destination' => $this->routesWaypoint($destinationPoint),
                        'travelMode' => 'DRIVE',
                        'routingPreference' => 'TRAFFIC_AWARE_OPTIMAL',
                        'computeAlternativeRoutes' => false,
                        'polylineQuality' => 'OVERVIEW',
                        'polylineEncoding' => 'ENCODED_POLYLINE',
                    ]);

                if (! $response->successful()) {
                    throw new \RuntimeException('Routes traffic API returned HTTP '.$response->status().'.');
                }

                $route = data_get($response->json(), 'routes.0');
                if (! is_array($route)) {
                    return null;
                }

                $durationSeconds = $this->googleDurationSeconds(data_get($route, 'duration'));
                $staticDurationSeconds = $this->googleDurationSeconds(data_get($route, 'staticDuration'));
                $delaySeconds = ($durationSeconds !== null && $staticDurationSeconds !== null)
                    ? max(0, $durationSeconds - $staticDurationSeconds)
                    : null;

                return [
                    'durationSeconds' => $durationSeconds,
                    'staticDurationSeconds' => $staticDurationSeconds,
                    'delaySeconds' => $delaySeconds,
                    'eta' => $durationSeconds !== null ? now()->addSeconds($durationSeconds)->toIso8601String() : null,
                    'distanceMeters' => data_get($route, 'distanceMeters'),
                    'encodedPolyline' => data_get($route, 'polyline.encodedPolyline'),
                    'speedReadingIntervals' => data_get($route, 'travelAdvisory.speedReadingIntervals', []),
                    'severity' => $this->trafficSeverity($durationSeconds, $staticDurationSeconds, $delaySeconds),
                    'source' => 'google_routes_traffic_aware',
                    'updatedAt' => now()->toIso8601String(),
                    'cachedForSeconds' => 180,
                ];
            } catch (\Throwable $e) {
                $this->logFailure('routes.traffic_aware', $e);

                return null;
            }
        });
    }

    /**
     * @param  array<string, mixed>  $depot
     * @param  array<int, array<string, mixed>>  $stops
     * @return array<string, mixed>
     */
    public function optimizeStopOrder(array $depot, array $stops): array
    {
        $depotPoint = $this->validPoint($depot);
        $validStops = array_values(array_filter(array_map(function (array $stop): ?array {
            $point = $this->validPoint((array) ($stop['coordinate'] ?? $stop));
            if ($point === null) {
                return null;
            }

            return [
                ...$stop,
                'coordinate' => $point,
            ];
        }, $stops)));

        if ($depotPoint === null || count($validStops) < 2) {
            return [
                'configured' => $this->isConfigured(),
                'optimized' => false,
                'source' => 'local_order',
                'message' => 'At least two valid stops and a depot coordinate are required.',
                'stops' => $validStops,
            ];
        }

        if (! $this->isConfigured()) {
            return [
                'configured' => false,
                'optimized' => false,
                'source' => 'local_order',
                'message' => 'Google Maps server key is not configured.',
                'stops' => $validStops,
            ];
        }

        $cacheKey = 'google_maps_routes_optimize_v1_'.md5(json_encode([
            'depot' => $this->roundedPoint($depotPoint, 5),
            'stops' => array_map(fn (array $stop): array => $this->roundedPoint($stop['coordinate'], 5), $validStops),
        ]));

        return Cache::remember($cacheKey, now()->addMinutes(5), function () use ($depotPoint, $validStops): array {
            try {
                $body = [
                    'origin' => $this->routesWaypoint($depotPoint),
                    'destination' => $this->routesWaypoint($depotPoint),
                    'intermediates' => array_map(
                        fn (array $stop): array => $this->routesWaypoint($stop['coordinate']),
                        $validStops,
                    ),
                    'travelMode' => 'DRIVE',
                    'optimizeWaypointOrder' => true,
                ];

                $response = $this->httpClient()
                    ->withHeaders([
                        'X-Goog-Api-Key' => $this->serverKey(),
                        'X-Goog-FieldMask' => 'routes.optimizedIntermediateWaypointIndex,routes.duration,routes.distanceMeters',
                    ])
                    ->post('https://routes.googleapis.com/directions/v2:computeRoutes', $body);

                if (! $response->successful()) {
                    throw new \RuntimeException('Routes API returned HTTP '.$response->status().'.');
                }

                $order = data_get($response->json(), 'routes.0.optimizedIntermediateWaypointIndex', []);
                if (! is_array($order) || $order === []) {
                    return [
                        'configured' => true,
                        'optimized' => false,
                        'source' => 'google_routes_compute_routes',
                        'message' => 'Routes API did not return an optimized order.',
                        'stops' => $validStops,
                    ];
                }

                $orderedStops = [];
                foreach ($order as $index) {
                    if (isset($validStops[(int) $index])) {
                        $orderedStops[] = [
                            ...$validStops[(int) $index],
                            'optimizedSequence' => count($orderedStops) + 1,
                        ];
                    }
                }

                return [
                    'configured' => true,
                    'optimized' => count($orderedStops) === count($validStops),
                    'source' => 'google_routes_compute_routes',
                    'message' => 'Suggested stop order from Google Routes API.',
                    'duration' => data_get($response->json(), 'routes.0.duration'),
                    'distanceMeters' => data_get($response->json(), 'routes.0.distanceMeters'),
                    'stops' => $orderedStops === [] ? $validStops : $orderedStops,
                ];
            } catch (\Throwable $e) {
                $this->logFailure('routes.optimize_order', $e);

                return [
                    'configured' => true,
                    'optimized' => false,
                    'source' => 'local_order',
                    'message' => 'Routes API unavailable; keeping current stop order.',
                    'stops' => $validStops,
                ];
            }
        });
    }

    /**
     * @param  array<string, mixed>  $coordinate
     * @return array<string, mixed>|null
     */
    public function reverseGeocode(array $coordinate): ?array
    {
        $point = $this->validPoint($coordinate);
        if ($point === null || ! $this->isConfigured()) {
            return null;
        }

        $cacheKey = 'google_maps_reverse_geocode_v1_'.md5(json_encode($this->roundedPoint($point, 5)));

        return Cache::remember($cacheKey, now()->addHours(24), function () use ($point): ?array {
            try {
                $response = $this->httpClient()
                    ->get('https://maps.googleapis.com/maps/api/geocode/json', [
                        'latlng' => $point['latitude'].','.$point['longitude'],
                        'language' => 'en',
                        'region' => 'ph',
                        'key' => $this->serverKey(),
                    ]);

                if (! $response->successful()) {
                    throw new \RuntimeException('Geocoding API returned HTTP '.$response->status().'.');
                }

                if ((string) $response->json('status') !== 'OK') {
                    return null;
                }

                $first = data_get($response->json(), 'results.0');
                $formatted = trim((string) data_get($first, 'formatted_address', ''));
                if ($formatted === '') {
                    return null;
                }

                return [
                    'formattedAddress' => $formatted,
                    'street' => $this->addressComponent($first, ['route', 'street_number']),
                    'city' => $this->addressComponent($first, ['locality', 'administrative_area_level_2']),
                    'country' => $this->addressComponent($first, ['country']),
                    'zones' => [],
                    'source' => 'google_geocoding',
                ];
            } catch (\Throwable $e) {
                $this->logFailure('geocoding.reverse', $e);

                return null;
            }
        });
    }

    /**
     * @return array<string, mixed>|null
     */
    public function nearestFuelStation(array $coordinate, int $radiusMeters = 75): ?array
    {
        $point = $this->validPoint($coordinate);
        if ($point === null || ! $this->isConfigured()) {
            return null;
        }

        $radiusMeters = max(25, min(250, $radiusMeters));
        $cacheKey = 'google_maps_nearest_fuel_station_v1_'.md5(json_encode([
            'point' => $this->roundedPoint($point, 4),
            'radius' => $radiusMeters,
        ]));

        return Cache::remember($cacheKey, now()->addDays(7), function () use ($point, $radiusMeters): ?array {
            try {
                $response = $this->httpClient()
                    ->withHeaders([
                        'X-Goog-Api-Key' => $this->serverKey(),
                        'X-Goog-FieldMask' => 'places.id,places.displayName,places.formattedAddress,places.location,places.types',
                    ])
                    ->post('https://places.googleapis.com/v1/places:searchNearby', [
                        'includedTypes' => ['gas_station'],
                        'maxResultCount' => 5,
                        'locationRestriction' => [
                            'circle' => [
                                'center' => [
                                    'latitude' => $point['latitude'],
                                    'longitude' => $point['longitude'],
                                ],
                                'radius' => $radiusMeters,
                            ],
                        ],
                    ]);

                if (! $response->successful()) {
                    throw new \RuntimeException('Places Nearby Search returned HTTP '.$response->status().'.');
                }

                $best = null;
                foreach ((array) $response->json('places', []) as $place) {
                    $latitude = data_get($place, 'location.latitude');
                    $longitude = data_get($place, 'location.longitude');
                    if (! is_numeric($latitude) || ! is_numeric($longitude)) {
                        continue;
                    }

                    $distance = $this->distanceMeters($point['latitude'], $point['longitude'], (float) $latitude, (float) $longitude);
                    if ($best === null || $distance < $best['distanceMeters']) {
                        $best = [
                            'placeId' => data_get($place, 'id'),
                            'name' => data_get($place, 'displayName.text', 'Nearby fuel station'),
                            'address' => data_get($place, 'formattedAddress'),
                            'distanceMeters' => round($distance, 1),
                            'confidence' => $distance <= 50 ? 'likely' : 'uncertain',
                            'source' => 'google_places_nearby_search',
                        ];
                    }
                }

                return $best;
            } catch (\Throwable $e) {
                $this->logFailure('places.nearest_fuel_station', $e);

                return null;
            }
        });
    }

    private function serverKey(): string
    {
        return trim((string) config('services.google_maps.server_key', ''));
    }

    private function httpClient(): PendingRequest
    {
        $request = Http::acceptJson()
            ->connectTimeout(self::CONNECT_TIMEOUT_SECONDS)
            ->timeout(self::READ_TIMEOUT_SECONDS);

        return app()->environment('local') ? $request->withoutVerifying() : $request;
    }

    /**
     * @param  array<int, array<string, mixed>>  $points
     * @return array<int, array{latitude: float, longitude: float}>
     */
    private function validPoints(array $points): array
    {
        return array_values(array_filter(array_map(
            fn (array $point): ?array => $this->validPoint($point),
            $points,
        )));
    }

    /**
     * @param  array<string, mixed>  $point
     * @return array{latitude: float, longitude: float}|null
     */
    private function validPoint(array $point): ?array
    {
        $latitude = $point['latitude'] ?? $point['lat'] ?? $point['y'] ?? null;
        $longitude = $point['longitude'] ?? $point['lng'] ?? $point['x'] ?? null;
        if (! is_numeric($latitude) || ! is_numeric($longitude)) {
            return null;
        }

        $latitude = (float) $latitude;
        $longitude = (float) $longitude;
        if (($latitude === 0.0 && $longitude === 0.0) || abs($latitude) > 90 || abs($longitude) > 180) {
            return null;
        }

        return [
            'latitude' => round($latitude, 6),
            'longitude' => round($longitude, 6),
        ];
    }

    /**
     * @param  array{latitude: float, longitude: float}  $point
     * @return array{latitude: float, longitude: float}
     */
    private function roundedPoint(array $point, int $precision): array
    {
        return [
            'latitude' => round((float) $point['latitude'], $precision),
            'longitude' => round((float) $point['longitude'], $precision),
        ];
    }

    /**
     * @param  array{latitude: float, longitude: float}  $point
     * @return array<string, mixed>
     */
    private function routesWaypoint(array $point): array
    {
        return [
            'location' => [
                'latLng' => [
                    'latitude' => $point['latitude'],
                    'longitude' => $point['longitude'],
                ],
            ],
        ];
    }

    private function distanceMeters(float $fromLat, float $fromLng, float $toLat, float $toLng): float
    {
        $earthRadius = 6371000;
        $latDelta = deg2rad($toLat - $fromLat);
        $lngDelta = deg2rad($toLng - $fromLng);
        $a = sin($latDelta / 2) ** 2
            + cos(deg2rad($fromLat)) * cos(deg2rad($toLat)) * sin($lngDelta / 2) ** 2;

        return $earthRadius * 2 * atan2(sqrt($a), sqrt(1 - $a));
    }

    private function googleDurationSeconds(mixed $duration): ?int
    {
        $raw = trim((string) $duration);
        if ($raw === '') {
            return null;
        }

        if (str_ends_with($raw, 's')) {
            $raw = substr($raw, 0, -1);
        }

        return is_numeric($raw) ? max(0, (int) round((float) $raw)) : null;
    }

    private function trafficSeverity(?int $durationSeconds, ?int $staticDurationSeconds, ?int $delaySeconds): string
    {
        if ($durationSeconds === null || $staticDurationSeconds === null || $staticDurationSeconds <= 0 || $delaySeconds === null) {
            return 'unknown';
        }

        $ratio = $durationSeconds / $staticDurationSeconds;
        if ($delaySeconds >= 900 || $ratio >= 1.55) {
            return 'heavy';
        }
        if ($delaySeconds >= 420 || $ratio >= 1.25) {
            return 'moderate';
        }
        if ($delaySeconds >= 120 || $ratio >= 1.1) {
            return 'light';
        }

        return 'clear';
    }

    /**
     * @param  array<string, mixed>|null  $result
     * @param  array<int, string>  $types
     */
    private function addressComponent(?array $result, array $types): string
    {
        foreach ((array) data_get($result, 'address_components', []) as $component) {
            $componentTypes = (array) ($component['types'] ?? []);
            if (array_intersect($types, $componentTypes) !== []) {
                return trim((string) ($component['long_name'] ?? ''));
            }
        }

        return '';
    }

    private function logFailure(string $operation, \Throwable $e): void
    {
        Log::channel('app_errors')->warning('PioneerPath Google Maps enrichment fallback', [
            'operation' => $operation,
            'errorType' => get_class($e),
            'errorMessage' => $e->getMessage(),
        ]);
    }
}
