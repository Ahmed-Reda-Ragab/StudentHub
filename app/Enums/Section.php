<?php

namespace App\Enums;

/**
 * Secondary-school grade + track. The backing value is what's stored in students.section.
 */
enum Section: string
{
    case Grade1 = 'grade_1';
    case Grade2Science = 'grade_2_science';
    case Grade2Arts = 'grade_2_arts';
    case Grade3Science = 'grade_3_science';
    case Grade3Math = 'grade_3_math';
    case Grade3Arts = 'grade_3_arts';

    public function label(): string
    {
        return __("students.sections.{$this->value}");
    }

    public function grade(): int
    {
        return (int) substr($this->value, 6, 1);
    }

    /**
     * Cases grouped by grade, for <optgroup> rendering.
     *
     * @return array<int, list<self>>
     */
    public static function grouped(): array
    {
        $groups = [];

        foreach (self::cases() as $case) {
            $groups[$case->grade()][] = $case;
        }

        return $groups;
    }
}
