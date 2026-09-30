<?php

namespace Tests\Feature\Students;

use App\Models\Student;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class StudentListTest extends TestCase
{
    use RefreshDatabase;

    private User $user;

    protected function setUp(): void
    {
        parent::setUp();

        $this->travelTo(CarbonImmutable::parse('2026-10-15 12:00', 'Africa/Cairo'));
        $this->user = User::factory()->create();
    }

    public function test_empty_state_is_shown_when_there_are_no_students(): void
    {
        $this->actingAs($this->user)->get('/students')
            ->assertOk()
            ->assertSee(__('students.add_first'));
    }

    public function test_search_matches_code_name_and_phone(): void
    {
        Student::factory()->for($this->user)->create(['name' => 'أحمد علي', 'code' => 'AB-100', 'phone' => '01011112222']);
        Student::factory()->for($this->user)->create(['name' => 'سارة محمود', 'code' => 'ZX-900', 'phone' => '01233334444']);

        $this->actingAs($this->user);

        $this->get('/students?q=AB-1')->assertSee('أحمد علي')->assertDontSee('سارة محمود');
        $this->get('/students?q='.urlencode('سارة'))->assertSee('سارة محمود')->assertDontSee('أحمد علي');
        $this->get('/students?q=3333')->assertSee('سارة محمود')->assertDontSee('أحمد علي');
        $this->get('/students?q=nothing-here')->assertSee('مفيش نتائج للبحث عن');
    }

    public function test_status_filter_and_counts(): void
    {
        $today = CarbonImmutable::today();

        Student::factory()->for($this->user)->renewsOn($today->subDays(3))->create(['name' => 'منتهي']);
        Student::factory()->for($this->user)->renewsOn($today)->create(['name' => 'اليوم']);
        Student::factory()->for($this->user)->renewsOn($today->addDay())->create(['name' => 'بكرة']);
        Student::factory()->for($this->user)->renewsOn($today->addDays(10))->create(['name' => 'فعال']);

        $this->actingAs($this->user);

        $response = $this->get('/students');
        $response->assertViewHas('counts', [
            'all' => 4, 'active' => 1, 'due_tomorrow' => 1, 'due_today' => 1, 'expired' => 1,
        ]);

        $this->get('/students?status=expired')->assertSee('منتهي')->assertDontSee('>فعال<', false)->assertDontSee('بكرة');
        $this->get('/students?status=due_tomorrow')->assertSee('بكرة')->assertDontSee('اليوم</a>', false);
    }

    public function test_list_is_ordered_by_number(): void
    {
        foreach (['ج', 'أ', 'ب'] as $name) {
            Student::factory()->for($this->user)->create(['name' => "طالب {$name}"]);
        }

        $this->actingAs($this->user)->get('/students')
            ->assertSeeInOrder(['طالب ج', 'طالب أ', 'طالب ب']);
    }

    public function test_bell_counts_expired_today_and_tomorrow(): void
    {
        $today = CarbonImmutable::today();
        Student::factory()->for($this->user)->renewsOn($today->subDay())->create();
        Student::factory()->for($this->user)->renewsOn($today->addDay())->create();
        Student::factory()->for($this->user)->renewsOn($today->addDays(5))->create();

        $this->actingAs($this->user)->get('/students')
            ->assertSee(__('app.nav.bell', ['count' => 2]));
    }
}
