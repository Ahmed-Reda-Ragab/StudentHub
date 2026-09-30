<?php

namespace App\Support;

use Carbon\CarbonImmutable;
use Carbon\CarbonInterface;

/**
 * Pure date math for a subscription period (fixed length in days).
 */
final class SubscriptionPeriod
{
    public function __construct(private readonly int $days = 30) {}

    public static function fromConfig(): self
    {
        return new self((int) config('subscriptions.period_days', 30));
    }

    public function days(): int
    {
        return $this->days;
    }

    public function endsOn(CarbonInterface $startDate): CarbonImmutable
    {
        return CarbonImmutable::parse($startDate->toDateString())->addDays($this->days);
    }
}
