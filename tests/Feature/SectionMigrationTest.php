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
        $migration = require database_path('migrations/2026_09_30_180000_convert_student_sections_to_fixed_list.php');

        $cases = [
            'أولى ثانوي' => ['grade_1', null],
            'الصف الاول' => ['grade_1', null],
            'تانية علمي' => ['grade_2_science', null],
            'ثانية ادبي' => ['grade_2_arts', null],
            'تالتة علمي رياضة' => ['grade_3_math', null],
            'تالته علوم' => ['grade_3_science', null],
            'ثالثة أدبي' => ['grade_3_arts', null],
            'تانية ثانوي' => [null, 'الشعبة القديمة: تانية ثانوي'],
            'ss' => [null, 'الشعبة القديمة: ss'],
        ];

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
