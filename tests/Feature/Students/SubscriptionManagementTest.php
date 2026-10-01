<?php

namespace Tests\Feature\Students;

use App\Enums\SubscriptionType;
use App\Models\Student;
use App\Models\Subscription;
use App\Models\User;
use App\Services\SubscriptionService;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class SubscriptionManagementTest extends TestCase
{
    use RefreshDatabase;

    private User $user;

    private Student $student;

    private Subscription $initial;

    private Subscription $renewal;

    protected function setUp(): void
    {
        parent::setUp();

        $this->travelTo(CarbonImmutable::parse('2026-11-10 09:00', 'Africa/Cairo'));

        $this->user = User::factory()->create();
        $this->student = Student::factory()->for($this->user)->subscribedOn('2026-10-01')->create();

        $this->actingAs($this->user);
        $this->renewal = app(SubscriptionService::class)->renew($this->student, CarbonImmutable::parse('2026-11-01'), 300, 100);
        $this->initial = $this->student->subscriptions()->where('type', SubscriptionType::Initial)->sole();
    }

    private function updateSubscription(Subscription $subscription, array $data)
    {
        return $this->from(route('students.show', $this->student))
            ->put(route('subscriptions.update', $subscription), $this->withSubmissionToken($data + [
                'start_date' => $subscription->start_date->toDateString(),
                'price' => '300',
                'commission' => '100',
            ]));
    }

    public function test_editing_the_latest_renewal_recalculates_the_student_dates(): void
    {
        $this->updateSubscription($this->renewal, ['start_date' => '2026-11-05', 'price' => '350', 'commission' => '120', 'note' => 'late'])
            ->assertRedirect(route('students.show', $this->student))
            ->assertSessionHasNoErrors();

        $this->renewal->refresh();
        $this->assertSame('2026-11-05', $this->renewal->start_date->toDateString());
        $this->assertSame('2026-12-04', $this->renewal->ends_on->toDateString());
        $this->assertSame('350.00', $this->renewal->price);
        $this->assertSame('120.00', $this->renewal->commission);
        $this->assertSame('late', $this->renewal->note);

        $this->student->refresh();
        $this->assertSame('2026-11-05', $this->student->last_subscription_date->toDateString());
        $this->assertSame('2026-12-05', $this->student->next_renewal_date->toDateString());
    }

    public function test_editing_the_initial_subscription_updates_the_first_date(): void
    {
        $this->updateSubscription($this->initial, ['start_date' => '2026-09-28'])->assertSessionHasNoErrors();

        $this->student->refresh();
        $this->assertSame('2026-09-28', $this->student->first_subscription_date->toDateString());
        $this->assertSame('2026-12-01', $this->student->next_renewal_date->toDateString());
    }

    public function test_a_date_cannot_cross_its_neighbours(): void
    {
        $this->updateSubscription($this->renewal, ['start_date' => '2026-10-01'])
            ->assertSessionHasErrorsIn('subscription', ['start_date']);

        $this->updateSubscription($this->initial, ['start_date' => '2026-11-15'])
            ->assertSessionHasErrorsIn('subscription', ['start_date']);

        $this->assertSame('2026-11-01', $this->renewal->refresh()->start_date->toDateString());
        $this->assertSame('2026-10-01', $this->initial->refresh()->start_date->toDateString());
    }

    public function test_commission_cannot_exceed_price(): void
    {
        $this->updateSubscription($this->renewal, ['price' => '100', 'commission' => '150'])
            ->assertSessionHasErrorsIn('subscription', ['commission']);
    }

    public function test_deleting_a_renewal_rolls_the_student_back_to_the_previous_entry(): void
    {
        $this->from(route('students.show', $this->student))
            ->delete(route('subscriptions.destroy', $this->renewal))
            ->assertRedirect(route('students.show', $this->student));

        $this->assertModelMissing($this->renewal);

        $this->student->refresh();
        $this->assertSame('2026-10-01', $this->student->last_subscription_date->toDateString());
        $this->assertSame('2026-11-01', $this->student->next_renewal_date->toDateString());
    }

    public function test_the_initial_subscription_cannot_be_deleted(): void
    {
        $this->from(route('students.show', $this->student))
            ->delete(route('subscriptions.destroy', $this->initial))
            ->assertSessionHas('toast.type', 'error');

        $this->assertModelExists($this->initial);
    }

    public function test_other_users_cannot_touch_the_subscription(): void
    {
        $this->actingAs(User::factory()->create());

        $this->updateSubscription($this->renewal, ['price' => '1'])->assertNotFound();
        $this->delete(route('subscriptions.destroy', $this->renewal))->assertNotFound();

        $this->assertModelExists($this->renewal);
    }
}
