<?php

namespace Tests\Feature;

use App\Models\Student;
use App\Models\User;
use App\Notifications\RenewalDueNotification;
use App\Services\NotificationSyncService;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Notification;
use Tests\TestCase;

class NotificationSyncTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->travelTo(CarbonImmutable::parse('2026-10-30 08:00', 'Africa/Cairo'));
    }

    public function test_first_screen_of_the_day_sends_one_digest_to_the_right_user_only(): void
    {
        Notification::fake();

        [$a, $b] = User::factory()->count(2)->create();
        Student::factory()->for($a)->count(2)->renewsOn('2026-10-31')->create();
        Student::factory()->for($b)->renewsOn('2026-11-20')->create();

        $this->actingAs($a)->get('/students')->assertOk();
        $this->actingAs($a)->get('/dashboard')->assertOk();
        $this->actingAs($a)->get('/students')->assertOk();

        Notification::assertSentToTimes($a, RenewalDueNotification::class, 1);
        Notification::assertSentTo($a, RenewalDueNotification::class,
            fn (RenewalDueNotification $n) => $n->toArray($a)['count'] === 2);

        $this->actingAs($b)->get('/students');
        Notification::assertNotSentTo($b, RenewalDueNotification::class);

        $this->assertSame('2026-10-30', $a->fresh()->notified_on->toDateString());
    }

    public function test_it_runs_again_on_the_next_day(): void
    {
        Notification::fake();

        $user = User::factory()->create();
        Student::factory()->for($user)->renewsOn('2026-10-31')->create();
        Student::factory()->for($user)->renewsOn('2026-11-01')->create();

        $this->actingAs($user)->get('/students');

        $this->travelTo(CarbonImmutable::parse('2026-10-31 08:00', 'Africa/Cairo'));
        $this->actingAs($user->fresh())->get('/students');

        Notification::assertSentToTimes($user, RenewalDueNotification::class, 2);
    }

    public function test_digest_is_stored_and_marked_read_on_notifications_page(): void
    {
        $user = User::factory()->create();
        Student::factory()->for($user)->renewsOn('2026-10-31')->create(['name' => 'طالب بكرة']);

        $this->actingAs($user)->get('/students');
        $this->assertSame(1, $user->unreadNotifications()->count());

        $this->actingAs($user)->get('/notifications')
            ->assertOk()
            ->assertSee('طالب بكرة')
            ->assertSee('طالب واحد تجديده غدًا');

        $this->assertSame(0, $user->unreadNotifications()->count());
    }

    public function test_skips_without_queries_when_already_synced_today(): void
    {
        $user = User::factory()->create();
        $service = app(NotificationSyncService::class);

        $this->assertTrue($service->syncFor($user));
        $this->assertFalse($service->syncFor($user));
    }

    public function test_notifications_page_groups_students_live(): void
    {
        $user = User::factory()->create();
        Student::factory()->for($user)->renewsOn('2026-10-20')->create(['name' => 'متأخر']);
        Student::factory()->for($user)->renewsOn('2026-10-30')->create(['name' => 'النهارده']);
        Student::factory()->for($user)->renewsOn('2026-10-31')->create(['name' => 'بكرة']);
        Student::factory()->for($user)->renewsOn('2026-11-15')->create(['name' => 'بعيد']);

        $this->actingAs($user)->get('/notifications')
            ->assertSeeInOrder(['متأخر', 'النهارده', 'بكرة'])
            ->assertDontSee('بعيد');
    }

    public function test_notifications_page_empty_state(): void
    {
        $this->actingAs(User::factory()->create())->get('/notifications')
            ->assertSee(__('notifications.empty'));
    }
}
