<?php

namespace Tests\Feature;

use App\Models\Student;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class DuplicateSubmissionTest extends TestCase
{
    use RefreshDatabase;

    /**
     * @return array<string, string>
     */
    private function payload(): array
    {
        return [
            'name' => 'أحمد',
            'phone' => '01012345678',
            'code' => 'DUP-1',
            'section' => 'grade_1',
            'subscribed_on' => '2026-10-01',
        ];
    }

    public function test_same_add_student_form_submitted_twice_creates_one_student(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-10-01 10:00'));
        $user = User::factory()->create();
        $token = 'c56a4180-65aa-42ec-a945-5fd21dec0538';

        $first = $this->actingAs($user)->post('/students', $this->withSubmissionToken($this->payload(), $token));
        $second = $this->actingAs($user)->post('/students', $this->withSubmissionToken($this->payload(), $token));

        $student = Student::sole();
        $first->assertRedirect(route('students.show', $student));
        // Replay lands on the same result instead of a validation error.
        $second->assertRedirect(route('students.show', $student));
    }

    public function test_without_token_the_unique_code_still_prevents_duplicates(): void
    {
        $user = User::factory()->create();

        $this->actingAs($user)->post('/students', $this->payload())->assertSessionHasNoErrors();
        $this->actingAs($user)->post('/students', $this->payload())->assertSessionHasErrors('code');

        $this->assertSame(1, Student::count());
    }

    public function test_a_failed_submission_releases_its_token(): void
    {
        $user = User::factory()->create();
        $token = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

        $this->actingAs($user)->post('/students', $this->withSubmissionToken(['name' => ''] + $this->payload(), $token))
            ->assertSessionHasErrors('name');

        $this->actingAs($user)->post('/students', $this->withSubmissionToken($this->payload(), $token))
            ->assertSessionHasNoErrors();

        $this->assertSame(1, Student::count());
    }
}
