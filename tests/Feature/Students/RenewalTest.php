<?php

namespace Tests\Feature\Students;

use App\Enums\SubscriptionStatus;
use App\Enums\SubscriptionType;
use App\Models\Student;
use App\Models\Subscription;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use LogicException;
use Tests\TestCase;

class RenewalTest extends TestCase
{
    use RefreshDatabase;

    private User $user;

    private Student $student;

    protected function setUp(): void
    {
        parent::setUp();

        $this->travelTo(CarbonImmutable::parse('2026-10-31 09:00', 'Africa/Cairo'));

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

        $this->renew('2026-10-31')
            ->assertRedirect(route('students.show', $this->student))
            ->assertSessionHas('toast');

        $this->student->refresh();
        $this->assertSame('2026-10-31', $this->student->last_subscription_date->toDateString());
        $this->assertSame('2026-11-30', $this->student->next_renewal_date->toDateString());
        $this->assertSame(SubscriptionStatus::Active, $this->student->status());

        $this->assertSame(
            [['2026-10-31', SubscriptionType::Renewal], ['2026-10-01', SubscriptionType::Initial]],
            $this->student->subscriptions->map(fn (Subscription $s) => [$s->start_date->toDateString(), $s->type])->all(),
        );
    }

    public function test_consecutive_renewals_follow_the_spec_chain(): void
    {
        $this->renew('2026-10-31');

        $this->travelTo(CarbonImmutable::parse('2026-11-30 09:00', 'Africa/Cairo'));
        $this->renew('2026-11-30');

        $this->student->refresh();
        $this->assertSame('2026-12-30', $this->student->next_renewal_date->toDateString());
        $this->assertCount(3, $this->student->subscriptions);
    }

    public function test_late_renewal_counts_from_the_renewal_date(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-11-05 09:00', 'Africa/Cairo'));
        $this->assertSame(SubscriptionStatus::Expired, $this->student->status());

        $this->renew('2026-11-05');

        $this->assertSame('2026-12-05', $this->student->refresh()->next_renewal_date->toDateString());
    }

    public function test_renewal_before_the_last_date_is_rejected(): void
    {
        $this->renew('2026-09-15')
            ->assertSessionHasErrorsIn('renewal', ['renewed_on']);

        $this->assertCount(1, $this->student->subscriptions()->get());
        $this->assertSame('2026-10-31', $this->student->refresh()->next_renewal_date->toDateString());
    }

    public function test_renewal_on_an_already_recorded_date_is_rejected(): void
    {
        $this->renew('2026-10-01')
            ->assertSessionHasErrorsIn('renewal', ['renewed_on' => __('subscriptions.messages.duplicate_renewal')]);

        $this->renew('2026-10-31')->assertSessionHasNoErrors();
        $this->renew('2026-10-31')
            ->assertSessionHasErrorsIn('renewal', ['renewed_on' => __('subscriptions.messages.duplicate_renewal')]);

        $this->assertCount(2, $this->student->subscriptions()->get());
    }

    public function test_double_submitting_the_same_renewal_form_creates_one_record(): void
    {
        $token = '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d';

        $first = $this->renew('2026-10-31', $token);
        $second = $this->renew('2026-10-31', $token);

        $first->assertRedirect(route('students.show', $this->student));
        $second->assertRedirect(route('students.show', $this->student));
        $second->assertSessionHasNoErrors();

        $this->assertCount(2, $this->student->subscriptions()->get());
    }

    public function test_subscriptions_are_append_only(): void
    {
        $subscription = $this->student->subscriptions()->sole();

        $this->expectException(LogicException::class);

        $subscription->update(['start_date' => '2020-01-01']);
    }

    public function test_ledger_cannot_be_deleted_either(): void
    {
        $this->expectException(LogicException::class);

        $this->student->subscriptions()->sole()->delete();
    }
}
