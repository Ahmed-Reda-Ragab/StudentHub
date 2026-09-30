<?php

namespace Database\Seeders;

use App\Models\User;
use App\Services\SubscriptionService;
use App\Support\SubscriptionPeriod;
use Carbon\CarbonImmutable;
use Illuminate\Database\Seeder;

/**
 * Two demo accounts (password: "password"). The first gets 30 students spread
 * across every status with realistic renewal histories — all written through
 * SubscriptionService so the ledger and denormalized dates stay consistent.
 */
class DemoSeeder extends Seeder
{
    private const SECTIONS = ['أولى ثانوي', 'تانية ثانوي', 'تالتة ثانوي'];

    /**
     * Days from today to each student's next renewal: expired (<0), today (0), tomorrow (1), active (>1).
     */
    private const RENEWAL_OFFSETS = [
        -14, -9, -5, -3, -2, -1,
        0, 0, 0,
        1, 1, 1, 1,
        2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 29,
    ];

    public function run(SubscriptionService $subscriptions, SubscriptionPeriod $period): void
    {
        $demo = User::factory()->create(['name' => 'أ. محمد', 'email' => 'demo@example.com']);
        User::factory()->create(['name' => 'أ. سارة', 'email' => 'demo2@example.com']);

        $today = CarbonImmutable::today();

        foreach (self::RENEWAL_OFFSETS as $i => $offset) {
            $renewals = fake()->numberBetween(0, 3);
            // Walk back so the latest renewal's next date lands (about) $offset days from today.
            $firstDate = $today->addDays($offset)->subMonthsNoOverflow($period->months() * ($renewals + 1));
            [$price, $commission] = fake()->randomElement([[200, 50], [200, 50], [200, 50], [250, 60], [150, 40]]);

            $student = $subscriptions->addStudent($demo, [
                'price' => $price,
                'commission' => $commission,
                'name' => fake('ar_EG')->name(),
                'phone' => '01'.fake()->randomElement(['0', '1', '2', '5']).fake()->numerify('########'),
                'code' => (string) (100001 + $i),
                'section' => self::SECTIONS[$i % count(self::SECTIONS)],
                'notes' => $i % 5 === 0 ? 'ملتزم بالحضور' : null,
                'subscribed_on' => $firstDate,
            ]);

            // On-time renewals: each one on the previous period's renewal date.
            $date = $firstDate;
            for ($r = 1; $r <= $renewals; $r++) {
                $date = $period->nextRenewal($date);
                $subscriptions->renew($student, $date, $price, $commission);
            }
        }
    }
}
