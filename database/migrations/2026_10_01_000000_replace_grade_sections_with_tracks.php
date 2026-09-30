<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;

/**
 * The first version of the section list was grade-based (grade_1 … grade_3_arts). It's now track-based.
 * Third-year values map 1:1; first/second-year values have no track, so they become NULL and the old
 * label is kept in notes — same convention as the free-text conversion before it.
 */
return new class extends Migration
{
    private const MAPPED = [
        'grade_3_science' => 'science',
        'grade_3_math' => 'math',
        'grade_3_arts' => 'arts',
    ];

    private const DROPPED = [
        'grade_1' => 'الصف الأول الثانوي',
        'grade_2_science' => 'الثاني الثانوي - علمي',
        'grade_2_arts' => 'الثاني الثانوي - أدبي',
    ];

    public function up(): void
    {
        DB::transaction(function () {
            foreach (self::MAPPED as $old => $new) {
                DB::table('students')->where('section', $old)->update(['section' => $new]);
            }

            DB::table('students')->whereIn('section', array_keys(self::DROPPED))
                ->select(['id', 'section', 'notes'])->orderBy('id')
                ->chunkById(500, function ($rows) {
                    foreach ($rows as $row) {
                        DB::table('students')->where('id', $row->id)->update([
                            'section' => null,
                            'notes' => trim('الشعبة القديمة: '.self::DROPPED[$row->section]."\n".$row->notes),
                        ]);
                    }
                });
        });
    }

    public function down(): void
    {
        foreach (self::MAPPED as $old => $new) {
            DB::table('students')->where('section', $new)->update(['section' => $old]);
        }
    }
};
