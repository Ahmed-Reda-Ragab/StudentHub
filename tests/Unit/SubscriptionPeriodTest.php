<?php

namespace Tests\Unit;

use App\Support\SubscriptionPeriod;
use Carbon\CarbonImmutable;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

class SubscriptionPeriodTest extends TestCase
{
    /**
     * @return array<string, array{string, string}>
     */
    public static function renewalDates(): array
    {
        return [
            // Spec §2.2
            'oct 1 → oct 31' => ['2026-10-01', '2026-10-31'],
            'oct 31 → nov 30' => ['2026-10-31', '2026-11-30'],
            'nov 30 → dec 30' => ['2026-11-30', '2026-12-30'],
            // Month / year boundaries
            'crosses year' => ['2026-12-15', '2027-01-14'],
            'non-leap february' => ['2027-02-01', '2027-03-03'],
            'leap february' => ['2028-02-01', '2028-03-02'],
            'jan 31 leap year' => ['2028-01-31', '2028-03-01'],
        ];
    }

    #[DataProvider('renewalDates')]
    public function test_next_renewal_is_start_plus_thirty_days(string $start, string $expected): void
    {
        $period = new SubscriptionPeriod(30);

        $this->assertSame($expected, $period->endsOn(CarbonImmutable::parse($start))->toDateString());
    }

    public function test_time_of_day_is_ignored(): void
    {
        $period = new SubscriptionPeriod(30);

        $this->assertSame('2026-10-31', $period->endsOn(CarbonImmutable::parse('2026-10-01 23:59:59'))->toDateString());
    }
}
