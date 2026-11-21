<?php

namespace Database\Seeders;

use App\Enums\Section;
use App\Models\User;
use App\Services\SubscriptionService;
use App\Support\SubscriptionPeriod;
use Carbon\CarbonImmutable;
use Illuminate\Database\Seeder;
use Illuminate\Support\Arr;

/**
 * Realistic volume for load tests (k6): N users × M students with renewal history,
 * written through SubscriptionService like real traffic.
 *
 *   LOADTEST_USERS=20 LOADTEST_STUDENTS_PER_USER=100 php artisan db:seed --class=LoadTestSeeder --force
 *
 * Users: loadtest1@example.com … loadtestN@example.com, password "password".
 * Idempotent: existing load-test users are skipped.
 */
class LoadTestSeeder extends Seeder
{
    public function run(SubscriptionService $subscriptions, SubscriptionPeriod $period): void
    {
        $users = (int) config('sre_lab.loadtest.users');
        $perUser = (int) config('sre_lab.loadtest.students_per_user');
        $today = CarbonImmutable::today();

        for ($u = 1; $u <= $users; $u++) {
            $email = "loadtest{$u}@example.com";

            if (User::query()->where('email', $email)->exists()) {
                continue;
            }

            $user = User::factory()->create(['name' => "Load Test {$u}", 'email' => $email]);

            for ($s = 1; $s <= $perUser; $s++) {
                $date = $today->subDays(fake()->numberBetween(0, 150));

                $student = $subscriptions->addStudent($user, [
                    'name' => fake('ar_EG')->name(),
                    'phone' => '01'.Arr::random(['0', '1', '2', '5']).fake()->numerify('########'),
                    'code' => (string) (500000 + $s),
                    'section' => Arr::random(Section::cases())->value,
                    'notes' => null,
                    'subscribed_on' => $date,
                ]);

                // On-time renewals while the next renewal date is still in the past.
                while (($next = $period->nextRenewal($date))->lessThanOrEqualTo($today) && fake()->boolean(80)) {
                    $subscriptions->renew($student, $next);
                    $date = $next;
                }
            }

            $this->command?->info("Seeded {$email} with {$perUser} students.");
        }
    }
}
