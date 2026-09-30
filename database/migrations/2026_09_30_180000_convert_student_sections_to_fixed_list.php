<?php

use App\Enums\Section;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * students.section goes from free text to a Section enum value.
 *
 * Free text is matched best-effort ("أولى ثانوي" → grade_1, "تانية علمي" → grade_2_science, …).
 * Anything that doesn't name both grade and track unambiguously becomes NULL ("not set"), and the
 * original text is kept at the top of notes so the teacher can pick the right section later.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('students', function (Blueprint $table) {
            $table->string('section', 100)->nullable()->change();
        });

        DB::transaction(function () {
            DB::table('students')->select(['id', 'section', 'notes'])->orderBy('id')
                ->chunkById(500, function ($rows) {
                    foreach ($rows as $row) {
                        $section = $this->match((string) $row->section);

                        DB::table('students')->where('id', $row->id)->update([
                            'section' => $section?->value,
                            'notes' => $section || trim((string) $row->section) === ''
                                ? $row->notes
                                : trim("الشعبة القديمة: {$row->section}\n".$row->notes),
                        ]);
                    }
                });
        });
    }

    public function down(): void
    {
        DB::table('students')->select(['id', 'section'])->orderBy('id')
            ->chunkById(500, function ($rows) {
                foreach ($rows as $row) {
                    DB::table('students')->where('id', $row->id)->update([
                        'section' => Section::tryFrom((string) $row->section)?->label() ?? '',
                    ]);
                }
            });

        Schema::table('students', function (Blueprint $table) {
            $table->string('section', 100)->nullable(false)->change();
        });
    }

    private function match(string $text): ?Section
    {
        if (Section::tryFrom($text)) {
            return Section::from($text);
        }

        // Normalize hamza/taa-marbuta variants so "اولي" / "أولى" / "الاول" all compare equal.
        $t = strtr($text, ['أ' => 'ا', 'إ' => 'ا', 'آ' => 'ا', 'ى' => 'ي', 'ة' => 'ه']);

        $grade = match (true) {
            (bool) preg_match('/اول|1|١/u', $t) => 1,
            (bool) preg_match('/ثاني|تاني|ثانيه|تانيه|2|٢/u', $t) => 2,
            (bool) preg_match('/ثالث|تالت|3|٣/u', $t) => 3,
            default => null,
        };

        $arts = (bool) preg_match('/ادبي/u', $t);
        $math = (bool) preg_match('/رياض/u', $t);
        $science = (bool) preg_match('/علمي|علوم/u', $t);

        return match (true) {
            $grade === 1 => Section::Grade1,
            $grade === 2 && $arts && ! $science => Section::Grade2Arts,
            $grade === 2 && $science && ! $arts => Section::Grade2Science,
            $grade === 3 && $arts && ! $science && ! $math => Section::Grade3Arts,
            $grade === 3 && $math && ! $arts => Section::Grade3Math,
            $grade === 3 && $science && ! $math && ! $arts => Section::Grade3Science,
            default => null,
        };
    }
};
