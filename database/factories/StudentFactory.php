<?php

namespace Database\Factories;

use App\Enums\SubscriptionType;
use App\Models\Student;
use App\Models\User;
use App\Support\SubscriptionPeriod;
use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Factories\Factory;

/**
 * Test/seed helper. Mirrors SubscriptionService's invariants (initial ledger row,
 * consistent denormalized dates); application code must use the service instead.
 *
 * @extends Factory<Student>
 */
class StudentFactory extends Factory
{
    public function definition(): array
    {
        $start = CarbonImmutable::today()->subDays(fake()->numberBetween(0, 25));

        return [
            'user_id' => User::factory(),
            'number' => fn (array $attributes) => self::nextNumberFor($attributes['user_id']),
            'name' => fake()->name(),
            'phone' => '01'.fake()->randomElement(['0', '1', '2', '5']).fake()->numerify('########'),
            'code' => fake()->unique()->numerify('######'),
            'section' => fake()->randomElement(['أولى ثانوي', 'تانية ثانوي', 'تالتة ثانوي']),
            'notes' => null,
            'first_subscription_date' => $start,
            'last_subscription_date' => $start,
            'next_renewal_date' => fn (array $attributes) => app(SubscriptionPeriod::class)
                ->endsOn(CarbonImmutable::parse($attributes['last_subscription_date'])),
        ];
    }

    /**
     * `count(n)` makes every model before inserting any, so the DB max alone would
     * hand out duplicates — also track numbers issued but not yet persisted.
     *
     * @var array<int, int>
     */
    private static array $issued = [];

    private static function nextNumberFor(int $userId): int
    {
        $persisted = (int) Student::withoutGlobalScopes()->where('user_id', $userId)->max('number');

        return self::$issued[$userId] = max($persisted, self::$issued[$userId] ?? 0) + 1;
    }

    public function subscribedOn(string|CarbonImmutable $date): static
    {
        $date = CarbonImmutable::parse($date);

        return $this->state([
            'first_subscription_date' => $date,
            'last_subscription_date' => $date,
        ]);
    }

    /**
     * Next renewal lands exactly on the given date.
     */
    public function renewsOn(string|CarbonImmutable $date): static
    {
        $days = app(SubscriptionPeriod::class)->days();

        return $this->subscribedOn(CarbonImmutable::parse($date)->subDays($days));
    }

    public function configure(): static
    {
        return $this->afterCreating(function (Student $student): void {
            $student->subscriptions()->create([
                'user_id' => $student->user_id,
                'type' => SubscriptionType::Initial,
                'start_date' => $student->last_subscription_date,
                'ends_on' => $student->next_renewal_date,
                'price' => config('subscriptions.pricing.price'),
                'commission' => config('subscriptions.pricing.commission'),
            ]);
        });
    }
}
