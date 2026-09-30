<?php

namespace Tests\Unit;

use App\Enums\SubscriptionStatus;
use Carbon\CarbonImmutable;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

class SubscriptionStatusTest extends TestCase
{
    /**
     * @return array<string, array{string, SubscriptionStatus}>
     */
    public static function statuses(): array
    {
        // Due date: 2026-10-31
        return [
            'well before' => ['2026-10-15', SubscriptionStatus::Active],
            'two days before' => ['2026-10-29', SubscriptionStatus::Active],
            'day before' => ['2026-10-30', SubscriptionStatus::DueTomorrow],
            'due day' => ['2026-10-31', SubscriptionStatus::DueToday],
            'day after' => ['2026-11-01', SubscriptionStatus::Expired],
            'long after' => ['2027-01-01', SubscriptionStatus::Expired],
        ];
    }

    #[DataProvider('statuses')]
    public function test_status_is_resolved_from_today_and_due_date(string $today, SubscriptionStatus $expected): void
    {
        $this->assertSame($expected, SubscriptionStatus::resolve(
            CarbonImmutable::parse('2026-10-31'),
            CarbonImmutable::parse($today),
        ));
    }

    public function test_time_of_day_does_not_affect_status(): void
    {
        $due = CarbonImmutable::parse('2026-10-31');

        $this->assertSame(SubscriptionStatus::DueToday, SubscriptionStatus::resolve($due, CarbonImmutable::parse('2026-10-31 23:59:59')));
        $this->assertSame(SubscriptionStatus::DueTomorrow, SubscriptionStatus::resolve($due, CarbonImmutable::parse('2026-10-30 00:00:01')));
    }
}
