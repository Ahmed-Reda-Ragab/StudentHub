<?php

namespace Tests\Feature;

use App\Models\Student;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

/**
 * Spec §5 — user B must never see or touch user A's data.
 */
class UserIsolationTest extends TestCase
{
    use RefreshDatabase;

    private User $owner;

    private User $intruder;

    private Student $student;

    protected function setUp(): void
    {
        parent::setUp();

        $this->travelTo(CarbonImmutable::parse('2026-10-15 12:00', 'Africa/Cairo'));

        $this->owner = User::factory()->create();
        $this->intruder = User::factory()->create();
        $this->student = Student::factory()->for($this->owner)
            ->renewsOn(CarbonImmutable::today())
            ->create(['name' => 'طالب سري', 'code' => 'SECRET-1']);
    }

    public function test_foreign_student_pages_return_404(): void
    {
        $this->actingAs($this->intruder);

        $this->get(route('students.show', $this->student))->assertNotFound();
        $this->get(route('students.edit', $this->student))->assertNotFound();
    }

    public function test_foreign_student_cannot_be_updated_renewed_or_deleted(): void
    {
        $this->actingAs($this->intruder);

        $this->put(route('students.update', $this->student), $this->withSubmissionToken([
            'name' => 'hacked', 'phone' => '01000000000', 'code' => 'X', 'section' => 'X',
        ]))->assertNotFound();

        $this->post(route('students.renewals.store', $this->student), $this->withSubmissionToken([
            'renewed_on' => '2026-10-15',
        ]))->assertNotFound();

        $this->delete(route('students.destroy', $this->student), $this->withSubmissionToken([]))->assertNotFound();

        $this->student->refresh();
        $this->assertSame('طالب سري', $this->student->name);
        $this->assertNotSoftDeleted($this->student);
        $this->assertCount(1, $this->student->subscriptions()->withoutGlobalScopes()->get());
    }

    public function test_foreign_students_are_invisible_in_lists_search_and_notifications(): void
    {
        $this->actingAs($this->intruder);

        $this->get('/students')->assertDontSee('طالب سري')->assertViewHas('counts', fn ($c) => $c['all'] === 0);
        $this->get('/students?q=SECRET')->assertDontSee('طالب سري');
        $this->get('/notifications')->assertDontSee('طالب سري');
        $this->get('/dashboard')->assertViewHas('counts', fn ($c) => $c['all'] === 0);
    }

    public function test_policy_denies_access_even_if_the_scope_is_bypassed(): void
    {
        $unscoped = Student::withoutGlobalScopes()->findOrFail($this->student->id);

        $this->assertFalse($this->intruder->can('view', $unscoped));
        $this->assertFalse($this->intruder->can('renew', $unscoped));
        $this->assertTrue($this->owner->can('renew', $unscoped));
    }
}
