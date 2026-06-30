<?php

namespace App\Services;

use Illuminate\Support\Carbon;

class TripBillingCalculator
{
    /**
     * @param  array<string, mixed>  $trip
     * @param  array<string, mixed>  $context
     * @return array<string, mixed>
     */
    public function calculate(array $trip, array $context = []): array
    {
        $settings = is_array($context['settings'] ?? null) ? $context['settings'] : [];
        $fuel = is_array($context['fuel'] ?? null) ? $context['fuel'] : [];
        $pod = is_array($context['pod'] ?? null) ? $context['pod'] : null;
        $manualTolls = is_array($context['manualTolls'] ?? null) ? $context['manualTolls'] : [];

        $amount = $this->moneyValue($trip['amount'] ?? 0);
        $distanceKm = max(0.0, (float) ($trip['distanceKm'] ?? $trip['distance'] ?? 0));
        $orderValue = $this->moneyValue($trip['orderValue'] ?? $trip['declaredValue'] ?? $amount);
        $baseRatePerKm = max(0.0, (float) ($settings['baseDeliveryChargePerKm'] ?? 65));
        $fuelSurchargeRate = max(0.0, (float) ($settings['fuelSurchargeRatePercent'] ?? 15));
        $vatRatePercent = max(0.0, min(100.0, (float) ($settings['vatRatePercent'] ?? 12)));
        $freeDeliveryThreshold = max(0.0, (float) ($settings['freeDeliveryThreshold'] ?? 100000));

        $tripCompleted = $this->tripCompleted($trip);
        $podReady = $this->podReady($pod);
        $manualReviewRequired = false;
        $reviewFlags = [];

        $baseCharge = $amount > 0 ? round($amount * 0.40, 2) : 0.0;
        $distanceCharge = $distanceKm > 0
            ? round($distanceKm * $baseRatePerKm, 2)
            : ($amount > 0 ? round($amount * 0.25, 2) : 0.0);

        if ($distanceKm <= 0) {
            $reviewFlags[] = [
                'key' => 'missing_distance',
                'label' => 'Distance review',
                'message' => 'No route distance was available, so the distance charge uses the configured fallback.',
                'severity' => 'warning',
            ];
            $manualReviewRequired = true;
        }

        $fuelEvidence = $this->fuelEvidenceForTrip($trip, $fuel, $amount, $fuelSurchargeRate);
        $fuelCharge = (float) $fuelEvidence['amount'];
        if (($fuelEvidence['confidence'] ?? '') !== 'exact') {
            $reviewFlags[] = [
                'key' => 'fuel_estimate',
                'label' => 'Fuel estimate',
                'message' => 'Fuel charge is not backed by an exact GeoTab fuel transaction or receipt.',
                'severity' => 'info',
            ];
        }

        $tollEvidence = $this->tollEvidenceForTrip($trip, $manualTolls);
        $tollCharge = (float) $tollEvidence['amount'];
        if ($tollCharge <= 0.0) {
            $reviewFlags[] = [
                'key' => 'toll_unavailable',
                'label' => 'Toll review',
                'message' => 'No supported toll estimate or manual toll receipt is attached to this trip.',
                'severity' => 'info',
            ];
        }

        $routeText = strtolower(implode(' ', [
            $trip['origin'] ?? '',
            $trip['destination'] ?? '',
            $trip['routeName'] ?? '',
            $trip['notes'] ?? '',
        ]));
        $thirdPartyCandidate = preg_match('/\b(ap cargo|lalamove|third[- ]party|courier|outsourced)\b/i', $routeText) === 1;
        $withinFreeDeliveryRadius = $distanceKm > 0 && $distanceKm <= 10;
        $freeDeliveryCandidate = $orderValue >= $freeDeliveryThreshold && $withinFreeDeliveryRadius;
        if ($thirdPartyCandidate || $freeDeliveryCandidate || ($tripCompleted && ! $podReady)) {
            $manualReviewRequired = true;
        }

        $knownCharges = $baseCharge + $distanceCharge + $fuelCharge + $tollCharge;
        $surcharges = $amount > 0 ? round(max(0.0, $amount - $knownCharges), 2) : 0.0;
        $subtotal = round($knownCharges + $surcharges, 2);
        $vatAmount = round($subtotal * ($vatRatePercent / 100), 2);
        $totalWithVat = round($subtotal + $vatAmount, 2);

        $calculationStatus = $this->calculationStatus($trip, $tripCompleted, $podReady, $manualReviewRequired);
        $podReadiness = match ($calculationStatus) {
            'ready_for_review' => 'Ready for review',
            'waiting_for_pod' => 'Hold for POD',
            'review_required' => 'Needs review',
            default => 'Draft estimate',
        };

        $lineItems = [
            $this->lineItem('Base delivery charge', $baseCharge, 'system_rule', 'estimated', 'Configured base share of the delivery charge.'),
            $this->lineItem('Distance charge', $distanceCharge, 'geotab_route', $distanceKm > 0 ? 'estimated' : 'inferred', 'Calculated from route distance and configured rate per kilometer.'),
            $this->lineItem('Fuel charge', $fuelCharge, (string) $fuelEvidence['source'], (string) $fuelEvidence['confidence'], (string) $fuelEvidence['note']),
        ];

        if ($tollCharge > 0.0) {
            $lineItems[] = $this->lineItem('Toll pass-through', $tollCharge, (string) $tollEvidence['source'], (string) $tollEvidence['confidence'], (string) $tollEvidence['note']);
        }
        if ($surcharges > 0.0) {
            $lineItems[] = $this->lineItem('Other approved delivery surcharges', $surcharges, 'manual_review', 'manual', 'Residual delivery surcharge requiring accounting visibility.');
        }
        $lineItems[] = $this->lineItem('Policy review', 0.0, 'system_rule', $manualReviewRequired ? 'manual' : 'exact', $manualReviewRequired ? 'Accounting review required before issue.' : 'No policy exception detected.');

        return [
            'baseCharge' => $baseCharge,
            'distanceCharge' => $distanceCharge,
            'fuelCharge' => $fuelCharge,
            'tollCharge' => $tollCharge,
            'surcharges' => $surcharges,
            'subtotal' => $subtotal,
            'vatAmount' => $vatAmount,
            'totalWithVat' => $totalWithVat,
            'vatRatePercent' => round($vatRatePercent, 2),
            'baseDeliveryChargePerKm' => round($baseRatePerKm, 2),
            'fuelSurchargeRatePercent' => round($fuelSurchargeRate, 2),
            'freeDeliveryThreshold' => round($freeDeliveryThreshold, 2),
            'freeDeliveryCandidate' => $freeDeliveryCandidate,
            'withinFreeDeliveryRadius' => $withinFreeDeliveryRadius,
            'thirdPartyCandidate' => $thirdPartyCandidate,
            'manualReviewRequired' => $manualReviewRequired,
            'podReady' => $podReady,
            'podStatus' => $podReady ? 'verified' : ($pod !== null ? (string) ($pod['status'] ?? 'submitted') : 'missing'),
            'podReadiness' => $podReadiness,
            'calculationStatus' => $calculationStatus,
            'itemizedBreakdown' => $lineItems,
            'chargeBreakdown' => $lineItems,
            'evidenceSummary' => [
                'distance' => [
                    'source' => $distanceKm > 0 ? 'GeoTab route/trip distance' : 'Fallback estimate',
                    'confidence' => $distanceKm > 0 ? 'estimated' : 'inferred',
                    'distanceKm' => round($distanceKm, 2),
                ],
                'fuel' => $fuelEvidence,
                'toll' => $tollEvidence,
                'pod' => [
                    'source' => 'PioneerPath POD',
                    'confidence' => $podReady ? 'exact' : 'missing',
                    'status' => $podReady ? 'verified' : 'required',
                ],
            ],
            'reviewFlags' => $reviewFlags,
            'manifest' => $this->manifestForTrip($trip),
            'lastCalculatedAt' => Carbon::now()->toIso8601String(),
        ];
    }

    /**
     * @param  array<string, mixed>  $trip
     * @param  array<string, mixed>  $fuel
     * @return array<string, mixed>
     */
    private function fuelEvidenceForTrip(array $trip, array $fuel, float $amount, float $fallbackRate): array
    {
        $vehicleKeys = array_values(array_filter(array_map(
            fn (mixed $value): string => strtolower(trim((string) $value)),
            [
                $trip['vehicle'] ?? null,
                $trip['vehiclePlate'] ?? null,
                $trip['assignedVehicle'] ?? null,
                $trip['deviceGeotabId'] ?? null,
                $trip['assignedVehicleGeotabId'] ?? null,
            ],
        )));

        $rows = [];
        foreach (['confirmedEvents', 'normalizedEvents', 'transactions', 'events'] as $bucket) {
            foreach (is_array($fuel[$bucket] ?? null) ? $fuel[$bucket] : [] as $row) {
                if (is_array($row) && $this->rowMatchesVehicle($row, $vehicleKeys)) {
                    $rows[] = $row;
                }
            }
        }

        usort($rows, fn (array $a, array $b): int => strcmp((string) ($b['dateTime'] ?? $b['eventAt'] ?? $b['date'] ?? ''), (string) ($a['dateTime'] ?? $a['eventAt'] ?? $a['date'] ?? '')));
        foreach ($rows as $row) {
            $cost = $this->moneyValue($row['totalCost'] ?? $row['cost'] ?? $row['amount'] ?? 0);
            $liters = (float) ($row['liters'] ?? $row['volume'] ?? $row['fuelUsedLiters'] ?? 0);
            $price = (float) ($row['pricePerLiter'] ?? $row['fuelPricePerLiter'] ?? 0);
            if ($cost <= 0 && $liters > 0 && $price > 0) {
                $cost = round($liters * $price, 2);
            }
            if ($cost <= 0) {
                continue;
            }

            $sourceType = strtolower((string) ($row['sourceType'] ?? $row['eventType'] ?? $row['source'] ?? 'fuel_event'));
            $exact = str_contains($sourceType, 'transaction') || strtolower((string) ($row['reviewStatus'] ?? '')) === 'confirmed';

            return [
                'amount' => $cost,
                'source' => $exact ? 'geotab_fuel_transaction' : 'fuel_event',
                'confidence' => $exact ? 'exact' : 'estimated',
                'note' => $exact ? 'Exact fuel cost from GeoTab transaction or confirmed receipt.' : 'Fuel event estimate from available fuel evidence.',
                'eventId' => $row['id'] ?? null,
                'stationName' => $row['stationName'] ?? $row['station'] ?? null,
                'liters' => $liters > 0 ? round($liters, 2) : null,
            ];
        }

        $fallback = round($amount * ($fallbackRate / 100), 2);

        return [
            'amount' => $fallback,
            'source' => 'system_fuel_surcharge',
            'confidence' => 'estimated',
            'note' => 'Fallback fuel surcharge from configured billing settings.',
            'eventId' => null,
        ];
    }

    /**
     * @param  array<string, mixed>  $trip
     * @param  array<int, array<string, mixed>>  $manualTolls
     * @return array<string, mixed>
     */
    private function tollEvidenceForTrip(array $trip, array $manualTolls): array
    {
        $manualTotal = round(array_sum(array_map(fn (array $row): float => $this->moneyValue($row['amount'] ?? 0), $manualTolls)), 2);
        if ($manualTotal > 0.0) {
            return [
                'amount' => $manualTotal,
                'source' => 'manual_toll_receipt',
                'confidence' => 'manual',
                'note' => 'Manual toll amount entered by Accounting or Dispatch.',
                'records' => $manualTolls,
            ];
        }

        $candidates = [
            $trip['tollCost'] ?? null,
            $trip['tollFees'] ?? null,
            $trip['tollEstimate'] ?? null,
            data_get($trip, 'traffic.tollInfo.estimatedPrice') ?? null,
            data_get($trip, 'routeTraffic.tollInfo.estimatedPrice') ?? null,
            data_get($trip, 'googleRoutes.tollInfo.estimatedPrice') ?? null,
        ];
        foreach ($candidates as $candidate) {
            $value = $this->moneyValue($candidate);
            if ($value > 0.0) {
                return [
                    'amount' => $value,
                    'source' => 'google_toll_estimate',
                    'confidence' => 'estimated',
                    'note' => 'Estimated toll from route intelligence; confirm before issue if a receipt is required.',
                    'records' => [],
                ];
            }
        }

        return [
            'amount' => 0.0,
            'source' => 'unavailable',
            'confidence' => 'missing',
            'note' => 'No toll estimate is available for this trip.',
            'records' => [],
        ];
    }

    /**
     * @param  array<string, mixed>  $row
     * @param  array<int, string>  $vehicleKeys
     */
    private function rowMatchesVehicle(array $row, array $vehicleKeys): bool
    {
        if ($vehicleKeys === []) {
            return false;
        }

        $values = array_values(array_filter(array_map(
            fn (mixed $value): string => strtolower(trim((string) $value)),
            [
                $row['vehicle'] ?? null,
                $row['plate'] ?? null,
                $row['vehiclePlate'] ?? null,
                $row['geotabId'] ?? null,
                $row['deviceId'] ?? null,
                $row['vehicleGeotabId'] ?? null,
            ],
        )));

        return array_intersect($vehicleKeys, $values) !== [];
    }

    /**
     * @param  array<string, mixed>  $trip
     * @return array<string, mixed>
     */
    private function manifestForTrip(array $trip): array
    {
        $manifest = is_array($trip['manifest'] ?? null) ? $trip['manifest'] : [];

        return [
            'cargoDescription' => $this->clean($manifest['cargoDescription'] ?? $trip['cargoDescription'] ?? $trip['cargoType'] ?? 'Truck parts delivery'),
            'packageCount' => $this->nullableNumber($manifest['packageCount'] ?? $trip['packageCount'] ?? $trip['itemCount'] ?? null),
            'declaredValue' => $this->moneyValue($manifest['declaredValue'] ?? $trip['declaredValue'] ?? $trip['orderValue'] ?? 0),
            'referenceNumber' => $this->clean($manifest['referenceNumber'] ?? $trip['referenceNumber'] ?? $trip['drNumber'] ?? $trip['poNumber'] ?? ''),
            'poNumber' => $this->clean($manifest['poNumber'] ?? $trip['poNumber'] ?? ''),
            'drNumber' => $this->clean($manifest['drNumber'] ?? $trip['drNumber'] ?? ''),
            'siNumber' => $this->clean($manifest['siNumber'] ?? $trip['siNumber'] ?? ''),
            'scope' => 'delivery_reference_only',
        ];
    }

    private function calculationStatus(array $trip, bool $tripCompleted, bool $podReady, bool $manualReviewRequired): string
    {
        $status = strtolower(trim((string) ($trip['status'] ?? '')));
        if (! $tripCompleted && in_array($status, ['dispatched', 'in_progress', 'in progress', 'on trip', 'ontrip'], true)) {
            return 'draft_estimate';
        }
        if ($tripCompleted && ! $podReady) {
            return 'waiting_for_pod';
        }
        if ($tripCompleted && $podReady && $manualReviewRequired) {
            return 'review_required';
        }
        if ($tripCompleted && $podReady) {
            return 'ready_for_review';
        }

        return 'draft_estimate';
    }

    private function tripCompleted(array $trip): bool
    {
        return in_array(strtolower(trim((string) ($trip['status'] ?? ''))), ['completed', 'delivered', 'closed', 'verified'], true);
    }

    private function podReady(?array $pod): bool
    {
        if ($pod === null) {
            return false;
        }

        return in_array(strtolower((string) ($pod['status'] ?? '')), ['delivered', 'completed', 'verified'], true)
            && (((bool) ($pod['hasSignature'] ?? false)) || count((array) ($pod['attachments'] ?? [])) > 0);
    }

    private function lineItem(string $label, float $amount, string $source, string $confidence, string $note): array
    {
        return [
            'label' => $label,
            'amount' => round(max(0.0, $amount), 2),
            'source' => $source,
            'confidence' => $confidence,
            'note' => $note,
        ];
    }

    private function moneyValue(mixed $value): float
    {
        if (is_numeric($value)) {
            return round((float) $value, 2);
        }

        $clean = preg_replace('/[^0-9.\-]/', '', (string) $value);

        return round((float) ($clean === '' ? 0 : $clean), 2);
    }

    private function nullableNumber(mixed $value): ?float
    {
        if ($value === null || trim((string) $value) === '') {
            return null;
        }

        return round((float) $value, 2);
    }

    private function clean(mixed $value): string
    {
        return trim(strip_tags((string) $value));
    }
}
