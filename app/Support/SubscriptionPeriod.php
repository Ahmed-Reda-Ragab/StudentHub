<?php

namespace App\Support;

use Carbon\CarbonImmutable;
use Carbon\CarbonInterface;

/**
 * Pure date math for a subscription period measured in calendar months.
 *
 *   start 05/09 → ends 04/10 (last covered day) → next renewal 05/10
 *   start 31/01 → ends 27/02                    → next renewal 28/02 (no overflow into March)
 */
final class SubscriptionPeriod
{
    public function __construct(private readonly int $months = 1) {}

    public static function fromConfig(): self
    {
        return new self((int) config('subscriptions.period_months', 1));
    }

    public function months(): int
    {
        return $this->months;
    }

    public function nextRenewal(CarbonInterface $startDate): CarbonImmutable
    {
        return CarbonImmutable::parse($startDate->toDateString())->addMonthsNoOverflow($this->months);
    }

    /**
     * Last day covered by the subscription — the day before the next renewal.
     */
    public function endsOn(CarbonInterface $startDate): CarbonImmutable
    {
        return $this->nextRenewal($startDate)->subDay();
    }
}
