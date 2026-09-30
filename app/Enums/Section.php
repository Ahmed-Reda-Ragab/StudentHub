<?php

namespace App\Enums;

/**
 * Student track. The backing value is what's stored in students.section.
 */
enum Section: string
{
    case Science = 'science';
    case Math = 'math';
    case Arts = 'arts';
    case AzharScience = 'azhar_science';
    case AzharArts = 'azhar_arts';
    case TrackMedicine = 'track_medicine';
    case TrackEngineering = 'track_engineering';
    case TrackHumanities = 'track_humanities';
    case TrackBusiness = 'track_business';

    public function label(): string
    {
        return __("students.sections.{$this->value}");
    }

    /**
     * general = الثانوية العامة, azhar = الأزهر, baccalaureate = مسارات البكالوريا.
     */
    public function group(): string
    {
        return match ($this) {
            self::Science, self::Math, self::Arts => 'general',
            self::AzharScience, self::AzharArts => 'azhar',
            default => 'baccalaureate',
        };
    }

    /**
     * Cases grouped for <optgroup> rendering.
     *
     * @return array<string, list<self>>
     */
    public static function grouped(): array
    {
        $groups = [];

        foreach (self::cases() as $case) {
            $groups[$case->group()][] = $case;
        }

        return $groups;
    }
}
