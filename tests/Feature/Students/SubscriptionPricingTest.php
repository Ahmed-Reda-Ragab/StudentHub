<?php

namespace Tests\Feature\Students;

use App\Models\Student;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class SubscriptionPricingTest extends TestCase
{
    use RefreshDatabase;

    private User $user;

    protected function setUp(): void
    {
        parent::setUp();

        $this->travelTo(CarbonImmutable::parse('2026-10-31 09:00', 'Africa/Cairo'));
        $this->user = User::factory()->create();
    }

    /**
     * @return array<string, mixed>
     */
    private function studentPayload(array $overrides = []): array
    {
        return $this->withSubmissionToken($overrides + [
            'name' => 'أحمد',
            'phone' => '01012345678',
            'code' => 'P-1',
            'section' => 'أولى',
            'subscribed_on' => '2026-10-31',
        ]);
    }

    public function test_defaults_are_200_price_and_50_commission(): void
    {
        $this->actingAs($this->user)->post('/students', $this->studentPayload())->assertSessionHasNoErrors();

        $subscription = Student::sole()->subscriptions()->sole();

        $this->assertSame('200.00', $subscription->price);
        $this->assertSame('50.00', $subscription->commission);
    }

    public function test_custom_price_and_commission_are_stored_on_the_initial_subscription(): void
    {
        $this->actingAs($this->user)
            ->post('/students', $this->studentPayload(['price' => '250', 'commission' => '75.5']))
            ->assertSessionHasNoErrors();

        $subscription = Student::sole()->subscriptions()->sole();

        $this->assertSame('250.00', $subscription->price);
        $this->assertSame('75.50', $subscription->commission);
    }

    public function test_commission_cannot_exceed_price_or_be_empty_or_negative(): void
    {
        $this->actingAs($this->user);

        $this->post('/students', $this->studentPayload(['price' => '100', 'commission' => '150']))
            ->assertSessionHasErrors(['commission' => __('validation.custom.commission.lte')]);

        $this->post('/students', $this->studentPayload(['price' => '', 'commission' => '-5']))
            ->assertSessionHasErrors(['price', 'commission']);

        $this->assertSame(0, Student::count());
    }

    public function test_each_renewal_records_its_own_price_and_commission(): void
    {
        $student = Student::factory()->for($this->user)->subscribedOn('2026-10-01')->create();

        $this->actingAs($this->user)
            ->post(route('students.renewals.store', $student), $this->withSubmissionToken([
                'renewed_on' => '2026-10-31', 'price' => '180', 'commission' => '40',
            ]))
            ->assertSessionHasNoErrors();

        $this->assertSame(
            [['180.00', '40.00'], ['200.00', '50.00']],
            $student->subscriptions()->get()->map(fn ($s) => [$s->price, $s->commission])->all(),
        );
    }

    public function test_renewal_rejects_commission_above_price_in_the_renewal_bag(): void
    {
        $student = Student::factory()->for($this->user)->subscribedOn('2026-10-01')->create();

        $this->actingAs($this->user)
            ->post(route('students.renewals.store', $student), $this->withSubmissionToken([
                'renewed_on' => '2026-10-31', 'price' => '100', 'commission' => '101',
            ]))
            ->assertSessionHasErrorsIn('renewal', ['commission']);

        $this->assertCount(1, $student->subscriptions()->get());
    }

    public function test_student_page_shows_prices_and_totals(): void
    {
        $student = Student::factory()->for($this->user)->subscribedOn('2026-10-01')->create();

        $this->actingAs($this->user)->post(route('students.renewals.store', $student), $this->withSubmissionToken([
            'renewed_on' => '2026-10-31', 'price' => '250', 'commission' => '60',
        ]));

        $this->actingAs($this->user)->get(route('students.show', $student))
            ->assertOk()
            ->assertSee('250')
            ->assertSee('450') // total paid: 200 + 250
            ->assertSee('110'); // total commission: 50 + 60
    }
}
