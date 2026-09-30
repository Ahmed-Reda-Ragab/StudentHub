<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * students.section goes from free text to a fixed list (see App\Enums\Section).
 *
 * Free text is matched best-effort ("علمي رياضة" → math, "ازهر ادبي" → azhar_arts, "مسار طب" → track_medicine, …).
 * Anything that doesn't name a track unambiguously becomes NULL ("not set"), and the original text is
 * kept at the top of notes so the teacher can pick the right section later.
 *
 * Values are string literals on purpose: this migration must keep working if the enum changes later.
 */
return new class extends Migration
{
    private const VALUES = [
        'science', 'math', 'arts', 'azhar_science', 'azhar_arts',
        'track_medicine', 'track_engineering', 'track_humanities', 'track_business',
    ];

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
                            'section' => $section,
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
        DB::table('students')->whereNull('section')->update(['section' => '']);

        Schema::table('students', function (Blueprint $table) {
            $table->string('section', 100)->nullable(false)->change();
        });
    }

    private function match(string $text): ?string
    {
        if (in_array($text, self::VALUES, true)) {
            return $text;
        }

        // Normalize hamza/taa-marbuta variants so "ادبي" / "أدبى" / "رياضه" / "رياضة" compare equal.
        $t = strtr($text, ['أ' => 'ا', 'إ' => 'ا', 'آ' => 'ا', 'ى' => 'ي', 'ة' => 'ه']);
        $has = fn (string $pattern) => (bool) preg_match("/{$pattern}/u", $t);

        $arts = $has('ادبي');
        $science = $has('علمي|علوم');
        $math = $has('رياض');

        return match (true) {
            $has('مسار') && $has('طب') => 'track_medicine',
            $has('مسار') && $has('هندس') => 'track_engineering',
            $has('مسار') && $has('اداب|فنون') => 'track_humanities',
            $has('مسار') && $has('اعمال') => 'track_business',
            $has('ازهر') && $arts && ! $science => 'azhar_arts',
            $has('ازهر') && $science && ! $arts => 'azhar_science',
            $has('ازهر') => null,
            $math && ! $arts => 'math',
            $science && ! $arts => 'science',
            $arts && ! $science => 'arts',
            default => null,
        };
    }
};
