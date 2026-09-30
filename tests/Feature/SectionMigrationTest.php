<?php

namespace Tests\Feature;

use App\Models\Student;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Tests\TestCase;

class SectionMigrationTest extends TestCase
{
    use RefreshDatabase;

    public function test_free_text_sections_are_mapped_and_ambiguous_ones_kept_in_notes(): void
    {
        $this->assertConversion('2026_09_30_180000_convert_student_sections_to_fixed_list.php', [
            'علمي علوم' => ['science', null],
            'علمي رياضه' => ['math', null],
            'تالتة رياضة' => ['math', null],
            'ادبي' => ['arts', null],
            'ازهر علمي' => ['azhar_science', null],
            'أزهر أدبى' => ['azhar_arts', null],
            'مسار طب' => ['track_medicine', null],
            'مسار هندسه' => ['track_engineering', null],
            'مسار اداب و فنون' => ['track_humanities', null],
            'مسار أعمال' => ['track_business', null],
            'تانية ثانوي' => [null, 'الشعبة القديمة: تانية ثانوي'],
            'ازهر' => [null, 'الشعبة القديمة: ازهر'],
        ]);
    }

    public function test_grade_based_values_from_the_first_list_are_converted(): void
    {
        $this->assertConversion('2026_10_01_000000_replace_grade_sections_with_tracks.php', [
            'grade_3_science' => ['science', null],
            'grade_3_math' => ['math', null],
            'grade_3_arts' => ['arts', null],
            'grade_1' => [null, 'الشعبة القديمة: الصف الأول الثانوي'],
            'grade_2_arts' => [null, 'الشعبة القديمة: الثاني الثانوي - أدبي'],
            'track_business' => ['track_business', null],
        ]);
    }

    /**
     * @param  array<string, array{0: ?string, 1: ?string}>  $cases  stored text => [expected section, expected notes]
     */
    private function assertConversion(string $file, array $cases): void
    {
        $migration = require database_path("migrations/{$file}");

        $ids = [];
        foreach (array_keys($cases) as $text) {
            $student = Student::factory()->create();
            DB::table('students')->where('id', $student->id)->update(['section' => $text, 'notes' => null]);
            $ids[$text] = $student->id;
        }

        $migration->up();

        foreach ($cases as $text => [$section, $notes]) {
            $row = DB::table('students')->find($ids[$text]);
            $this->assertSame($section, $row->section, $text);
            $this->assertSame($notes, $row->notes, $text);
        }
    }
}
