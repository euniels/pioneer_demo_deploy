<?php

use App\Services\TripBillingCalculator;

test('trip billing calculator labels exact fuel evidence and missing tolls clearly', function (): void {
    $calculator = new TripBillingCalculator();

    $result = $calculator->calculate([
        'tripId' => 'DEMO-TRIP-001',
        'status' => 'completed',
        'customer' => 'Demo Client',
        'vehicle' => 'DEMO-TRK-01',
        'amount' => 10000,
        'distanceKm' => 24,
        'orderValue' => 85000,
    ], [
        'settings' => [
            'baseDeliveryChargePerKm' => 65,
            'fuelSurchargeRatePercent' => 15,
            'vatRatePercent' => 12,
            'freeDeliveryThreshold' => 100000,
        ],
        'fuel' => [
            'confirmedEvents' => [[
                'id' => 'fuel-001',
                'vehicle' => 'DEMO-TRK-01',
                'eventType' => 'confirmed_transaction',
                'sourceType' => 'fuel_transaction',
                'reviewStatus' => 'confirmed',
                'totalCost' => 2450,
                'liters' => 35,
                'stationName' => 'Demo Station',
            ]],
        ],
        'pod' => [
            'status' => 'verified',
            'hasSignature' => true,
            'attachments' => [],
        ],
    ]);

    expect($result['calculationStatus'])->toBe('ready_for_review')
        ->and($result['evidenceSummary']['fuel']['confidence'])->toBe('exact')
        ->and($result['evidenceSummary']['fuel']['source'])->toBe('geotab_fuel_transaction')
        ->and($result['reviewFlags'])->toContain(fn (array $flag): bool => $flag['key'] === 'toll_unavailable')
        ->and($result['manifest']['scope'])->toBe('delivery_reference_only');
});

test('trip billing calculator keeps completed trips on pod hold until proof is verified', function (): void {
    $calculator = new TripBillingCalculator();

    $result = $calculator->calculate([
        'tripId' => 'DEMO-TRIP-002',
        'status' => 'completed',
        'vehicle' => 'DEMO-TRK-02',
        'amount' => 8500,
        'distanceKm' => 18,
    ], [
        'settings' => [
            'baseDeliveryChargePerKm' => 65,
            'fuelSurchargeRatePercent' => 15,
            'vatRatePercent' => 12,
            'freeDeliveryThreshold' => 100000,
        ],
    ]);

    expect($result['calculationStatus'])->toBe('waiting_for_pod')
        ->and($result['podReady'])->toBeFalse()
        ->and($result['podReadiness'])->toBe('Hold for POD')
        ->and($result['evidenceSummary']['fuel']['confidence'])->toBe('estimated');
});
