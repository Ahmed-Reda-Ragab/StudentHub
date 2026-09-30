<?php

namespace Tests\Feature\Students;

use App\Enums\Section;
use App\Enums\SubscriptionType;
use App\Models\Student;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class CreateStudentTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->travelTo(CarbonImmutable::parse('2026-10-01 10:00', 'Africa/Cairo'));
    }

    /**
     * @return array<string, mixed>
     */
    private function payload(array $overrides = []): array
    {
        return $this->withSubmissionToken($overrides + [
            'name' => 'أحمد علي',
            'phone' => '010 1234 5678',
            'code' => '123456',
            'section' => 'grade_1',
            'subscribed_on' => '2026-10-01',
            'notes' => 'طالب ممتاز',
        ]);
    }

    public function test_adding_a_student_creates_initial_subscription_and_computes_renewal(): void
    {
        $user = User::factory()->create();

        $response = $this->actingAs($user)->post('/students', $this->payload());

        $student = Student::sole();
        $response->assertRedirect(route('students.show', $student));

        $this->assertSame(1, $student->number);
        $this->assertSame($user->id, $student->user_id);
        $this->assertSame('01012345678', $student->phone);
        $this->assertSame('2026-10-01', $student->first_subscription_date->toDateString());
        $this->assertSame('2026-10-01', $student->last_subscription_date->toDateString());
        $this->assertSame('2026-11-01', $student->next_renewal_date->toDateString());

        // Covered until the day before the next renewal.
        $subscription = $student->subscriptions()->sole();
        $this->assertSame(SubscriptionType::Initial, $subscription->type);
        $this->assertSame('2026-10-31', $subscription->ends_on->toDateString());

        $this->actingAs($user)->get(route('students.show', $student))
            ->assertSee('31/10/2026')
            ->assertSee('01/11/2026');
    }

    public function test_numbers_are_sequential_per_user_and_independent_between_users(): void
    {
        [$a, $b] = User::factory()->count(2)->create();

        $this->actingAs($a)->post('/students', $this->payload(['code' => 'A1']));
        $this->actingAs($a)->post('/students', $this->payload(['code' => 'A2']));
        $this->actingAs($b)->post('/students', $this->payload(['code' => 'B1']));

        $this->assertSame([1, 2], Student::withoutGlobalScopes()->where('user_id', $a->id)->orderBy('number')->pluck('number')->all());
        $this->assertSame([1], Student::withoutGlobalScopes()->where('user_id', $b->id)->pluck('number')->all());
    }

    public function test_numbers_are_never_reused_after_soft_delete(): void
    {
        $user = User::factory()->create();

        $this->actingAs($user)->post('/students', $this->payload(['code' => 'X1']));
        $this->actingAs($user)->post('/students', $this->payload(['code' => 'X2']));

        $second = Student::where('code', 'X2')->sole();
        $this->actingAs($user)->delete(route('students.destroy', $second), $this->withSubmissionToken([]))
            ->assertRedirect(route('students.index'));
        $this->assertSoftDeleted($second);

        $this->actingAs($user)->post('/students', $this->payload(['code' => 'X3']));

        $this->assertSame(3, Student::where('code', 'X3')->sole()->number);
    }

    public function test_code_must_be_unique_per_user_but_can_repeat_across_users(): void
    {
        [$a, $b] = User::factory()->count(2)->create();

        $this->actingAs($a)->post('/students', $this->payload(['code' => 'SAME']));

        $this->actingAs($a)->post('/students', $this->payload(['code' => 'SAME']))
            ->assertSessionHasErrors(['code' => __('validation.custom.code.unique')]);

        $this->actingAs($b)->post('/students', $this->payload(['code' => 'SAME']))
            ->assertSessionHasNoErrors();

        $this->assertSame(2, Student::withoutGlobalScopes()->count());
    }

    public function test_required_fields_are_validated_in_arabic(): void
    {
        $user = User::factory()->create();

        $this->actingAs($user)
            ->post('/students', $this->withSubmissionToken([]))
            ->assertSessionHasErrors([
                'name' => 'الاسم مطلوب.',
                'phone', 'code', 'section', 'subscribed_on',
            ]);
    }

    public function test_section_must_be_one_of_the_fixed_list(): void
    {
        $user = User::factory()->create();

        $this->actingAs($user)->post('/students', $this->payload(['section' => 'أولى ثانوي']))
            ->assertSessionHasErrors('section');

        $this->actingAs($user)->post('/students', $this->payload(['section' => 'grade_2_arts']));

        $student = Student::sole();
        $this->assertSame(Section::Grade2Arts, $student->section);

        $this->actingAs($user)->get(route('students.create'))
            ->assertSee('الثاني الثانوي - علمي')
            ->assertSee('الثالث الثانوي - علمي رياضة');

        $this->actingAs($user)->get(route('students.show', $student))
            ->assertSee('الثاني الثانوي - أدبي');
    }

    public function test_subscription_dates_cannot_be_changed_via_update(): void
    {
        $user = User::factory()->create();
        $student = Student::factory()->for($user)->subscribedOn('2026-10-01')->create();

        $this->actingAs($user)->put(route('students.update', $student), $this->withSubmissionToken([
            'name' => 'اسم جديد',
            'phone' => '01111111111',
            'code' => $student->code,
            'section' => 'grade_2_science',
            'last_subscription_date' => '2020-01-01',
            'next_renewal_date' => '2020-01-31',
        ]))->assertRedirect(route('students.show', $student));

        $student->refresh();
        $this->assertSame('اسم جديد', $student->name);
        $this->assertSame('2026-11-01', $student->next_renewal_date->toDateString());
    }
}
