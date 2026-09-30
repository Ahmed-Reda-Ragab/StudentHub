<?php

namespace Tests\Feature;

use App\Models\Student;
use App\Models\User;
use App\Services\SubscriptionService;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class ReportTest extends TestCase
{
    use RefreshDatabase;

    private User $user;

    protected function setUp(): void
    {
        parent::setUp();

        $this->travelTo(CarbonImmutable::parse('2026-10-20 10:00', 'Africa/Cairo'));
        $this->user = User::factory()->create();
    }

    private function subscribe(User $user, string $date, int $price, int $commission, string $code): Student
    {
        return app(SubscriptionService::class)->addStudent($user, [
            'name' => "طالب {$code}", 'phone' => '01012345678', 'code' => $code, 'section' => 'أولى',
            'subscribed_on' => $date, 'price' => $price, 'commission' => $commission,
        ]);
    }

    public function test_totals_cover_only_the_selected_range(): void
    {
        $student = $this->subscribe($this->user, '2026-09-10', 200, 50, 'A'); // outside
        app(SubscriptionService::class)->renew($student, CarbonImmutable::parse('2026-10-10'), 250, 60); // inside
        $this->subscribe($this->user, '2026-10-05', 200, 50, 'B'); // inside
        $this->subscribe($this->user, '2026-10-15', 150, 40, 'C'); // inside

        $this->actingAs($this->user)->get('/reports?from=2026-10-01&to=2026-10-31')
            ->assertOk()
            ->assertViewHas('totals', [
                'count' => 3,
                'initial_count' => 2,
                'renewal_count' => 1,
                'price_total' => 600.0,
                'commission_total' => 150.0,
            ])
            ->assertViewHas('daily', fn ($daily) => $daily->count() === 3)
            ->assertSee('طالب C')
            ->assertSee('600');
    }

    public function test_range_boundaries_are_inclusive(): void
    {
        $this->subscribe($this->user, '2026-10-01', 200, 50, 'A');
        $this->subscribe($this->user, '2026-10-02', 200, 50, 'B');
        $this->subscribe($this->user, '2026-10-03', 200, 50, 'C');

        $this->actingAs($this->user)->get('/reports?from=2026-10-01&to=2026-10-02')
            ->assertViewHas('totals', fn ($t) => $t['count'] === 2 && $t['price_total'] === 400.0);
    }

    public function test_defaults_to_the_current_month(): void
    {
        $this->subscribe($this->user, '2026-09-30', 200, 50, 'OLD');
        $this->subscribe($this->user, '2026-10-01', 200, 50, 'NEW');

        $this->actingAs($this->user)->get('/reports')
            ->assertViewHas('from', fn ($from) => $from->toDateString() === '2026-10-01')
            ->assertViewHas('to', fn ($to) => $to->toDateString() === '2026-10-20')
            ->assertViewHas('totals', fn ($t) => $t['count'] === 1);
    }

    public function test_other_users_money_is_never_included(): void
    {
        $this->subscribe(User::factory()->create(), '2026-10-05', 999, 99, 'X');

        $this->actingAs($this->user)->get('/reports?from=2026-10-01&to=2026-10-31')
            ->assertViewHas('totals', fn ($t) => $t['count'] === 0 && $t['price_total'] === 0.0)
            ->assertSee(__('reports.empty'))
            ->assertDontSee('طالب X');
    }

    public function test_end_date_before_start_date_is_rejected(): void
    {
        $this->actingAs($this->user)->from('/reports')
            ->get('/reports?from=2026-10-10&to=2026-10-01')
            ->assertRedirect('/reports')
            ->assertSessionHasErrors('to');
    }
}
