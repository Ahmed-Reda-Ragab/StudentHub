<?php

namespace Tests\Feature\Students;

use App\Enums\SubscriptionStatus;
use App\Enums\SubscriptionType;
use App\Models\Student;
use App\Models\Subscription;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class RenewalTest extends TestCase
{
    use RefreshDatabase;

    private User $user;

    private Student $student;

    protected function setUp(): void
    {
        parent::setUp();

        // Subscribed 01/10 → covered until 31/10 → renewal due 01/11 (today).
        $this->travelTo(CarbonImmutable::parse('2026-11-01 09:00', 'Africa/Cairo'));

        $this->user = User::factory()->create();
        $this->student = Student::factory()->for($this->user)->subscribedOn('2026-10-01')->create();
    }

    private function renew(string $date, ?string $token = null)
    {
        return $this->actingAs($this->user)
            ->from(route('students.show', $this->student))
            ->post(route('students.renewals.store', $this->student), $this->withSubmissionToken(['renewed_on' => $date], $token));
    }

    public function test_renewal_appends_to_history_and_moves_the_next_date(): void
    {
        $this->assertSame(SubscriptionStatus::DueToday, $this->student->status());

        $this->renew('2026-11-01')
            ->assertRedirect(route('students.show', $this->student))
            ->assertSessionHas('toast');

        $this->student->refresh();
        $this->assertSame('2026-11-01', $this->student->last_subscription_date->toDateString());
        $this->assertSame('2026-12-01', $this->student->next_renewal_date->toDateString());
        $this->assertSame(SubscriptionStatus::Active, $this->student->status());

        $this->assertSame(
            [
                ['2026-11-01', '2026-11-30', SubscriptionType::Renewal],
                ['2026-10-01', '2026-10-31', SubscriptionType::Initial],
            ],
            $this->student->subscriptions->map(fn (Subscription $s) => [
                $s->start_date->toDateString(), $s->ends_on->toDateString(), $s->type,
            ])->all(),
        );
    }

    public function test_consecutive_renewals_keep_the_same_day_of_month(): void
    {
        $this->renew('2026-11-01');

        $this->travelTo(CarbonImmutable::parse('2026-12-01 09:00', 'Africa/Cairo'));
        $this->renew('2026-12-01');

        $this->student->refresh();
        $this->assertSame('2027-01-01', $this->student->next_renewal_date->toDateString());
        $this->assertCount(3, $this->student->subscriptions);
    }

    public function test_late_renewal_counts_from_the_renewal_date(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-11-05 09:00', 'Africa/Cairo'));
        $this->assertSame(SubscriptionStatus::Expired, $this->student->status());

        $this->renew('2026-11-05');

        $this->student->refresh();
        $this->assertSame('2026-12-05', $this->student->next_renewal_date->toDateString());
        $this->assertSame('2026-12-04', $this->student->subscriptions->first()->ends_on->toDateString());
    }

    public function test_renewal_before_the_last_date_is_rejected(): void
    {
        $this->renew('2026-09-15')
            ->assertSessionHasErrorsIn('renewal', ['renewed_on']);

        $this->assertCount(1, $this->student->subscriptions()->get());
        $this->assertSame('2026-11-01', $this->student->refresh()->next_renewal_date->toDateString());
    }

    public function test_renewal_on_an_already_recorded_date_is_rejected(): void
    {
        $this->renew('2026-10-01')
            ->assertSessionHasErrorsIn('renewal', ['renewed_on' => __('subscriptions.messages.duplicate_renewal')]);

        $this->renew('2026-11-01')->assertSessionHasNoErrors();
        $this->renew('2026-11-01')
            ->assertSessionHasErrorsIn('renewal', ['renewed_on' => __('subscriptions.messages.duplicate_renewal')]);

        $this->assertCount(2, $this->student->subscriptions()->get());
    }

    public function test_double_submitting_the_same_renewal_form_creates_one_record(): void
    {
        $token = '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d';

        $first = $this->renew('2026-11-01', $token);
        $second = $this->renew('2026-11-01', $token);

        $first->assertRedirect(route('students.show', $this->student));
        $second->assertRedirect(route('students.show', $this->student));
        $second->assertSessionHasNoErrors();

        $this->assertCount(2, $this->student->subscriptions()->get());
    }
}
