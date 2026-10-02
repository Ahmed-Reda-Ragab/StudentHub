<?php

namespace Tests\Feature;

use App\Enums\Section;
use App\Models\Student;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class DashboardTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_counts_students_per_section_for_the_signed_in_user_only(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-10-15 12:00', 'Africa/Cairo'));

        $user = User::factory()->create();
        $other = User::factory()->create();

        Student::factory()->for($user)->count(2)->create(['section' => Section::Science]);
        Student::factory()->for($user)->create(['section' => Section::TrackMedicine]);
        Student::factory()->for($user)->create(['section' => null]);
        Student::factory()->for($user)->create(['section' => Section::Arts])->delete();
        Student::factory()->for($other)->count(3)->create(['section' => Section::Science]);

        $this->actingAs($user)
            ->get('/dashboard')
            ->assertOk()
            ->assertViewHas('sectionCounts', function (array $counts) {
                return $counts[Section::Science->value] === 2
                    && $counts[Section::TrackMedicine->value] === 1
                    && $counts[Section::Arts->value] === 0
                    && $counts[Section::Math->value] === 0
                    && $counts[''] === 1;
            })
            ->assertSee(__('dashboard.sections.title'))
            ->assertSee(Section::TrackMedicine->label())
            ->assertSee(__('dashboard.sections.missing', ['count' => 1]));
    }
}
