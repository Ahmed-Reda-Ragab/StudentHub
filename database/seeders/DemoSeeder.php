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
            $firstDate = $today->addDays($offset - $period->days() * ($renewals + 1));

            $student = $subscriptions->addStudent($demo, [
                'name' => fake('ar_EG')->name(),
                'phone' => '01'.fake()->randomElement(['0', '1', '2', '5']).fake()->numerify('########'),
                'code' => (string) (100001 + $i),
                'section' => self::SECTIONS[$i % count(self::SECTIONS)],
                'notes' => $i % 5 === 0 ? 'ملتزم بالحضور' : null,
                'subscribed_on' => $firstDate,
            ]);

            for ($r = 1; $r <= $renewals; $r++) {
                $subscriptions->renew($student, $firstDate->addDays($period->days() * $r));
            }
        }
    }
}
