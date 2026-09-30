<?php

namespace Tests\Unit;

use App\Support\SubscriptionPeriod;
use Carbon\CarbonImmutable;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

class SubscriptionPeriodTest extends TestCase
{
    /**
     * start → [last covered day, next renewal]
     *
     * @return array<string, array{string, string, string}>
     */
    public static function periods(): array
    {
        return [
            'client example: 5/9' => ['2026-09-05', '2026-10-04', '2026-10-05'],
            'first of month' => ['2026-10-01', '2026-10-31', '2026-11-01'],
            '31st into 30-day month' => ['2026-10-31', '2026-11-29', '2026-11-30'],
            'crosses year' => ['2026-12-15', '2027-01-14', '2027-01-15'],
            '31 jan, non-leap year' => ['2027-01-31', '2027-02-27', '2027-02-28'],
            '31 jan, leap year' => ['2028-01-31', '2028-02-28', '2028-02-29'],
            '29 feb, leap year' => ['2028-02-29', '2028-03-28', '2028-03-29'],
        ];
    }

    #[DataProvider('periods')]
    public function test_period_ends_the_day_before_the_same_day_next_month(string $start, string $endsOn, string $next): void
    {
        $period = new SubscriptionPeriod(1);
        $start = CarbonImmutable::parse($start);

        $this->assertSame($endsOn, $period->endsOn($start)->toDateString());
        $this->assertSame($next, $period->nextRenewal($start)->toDateString());
    }

    public function test_time_of_day_is_ignored(): void
    {
        $period = new SubscriptionPeriod(1);

        $this->assertSame('2026-11-01', $period->nextRenewal(CarbonImmutable::parse('2026-10-01 23:59:59'))->toDateString());
    }

    public function test_multi_month_periods(): void
    {
        $this->assertSame('2027-01-04', (new SubscriptionPeriod(3))->endsOn(CarbonImmutable::parse('2026-10-05'))->toDateString());
    }
}
