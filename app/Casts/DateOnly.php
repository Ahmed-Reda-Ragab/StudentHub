<?php

namespace App\Casts;

use Carbon\CarbonImmutable;
use Carbon\CarbonInterface;
use Illuminate\Contracts\Database\Eloquent\CastsAttributes;
use Illuminate\Database\Eloquent\Model;

/**
 * Calendar date without time. Unlike the built-in `date` cast (which persists
 * "Y-m-d H:i:s"), this stores plain "Y-m-d" so equality/range comparisons on the
 * raw column behave identically on MySQL and SQLite.
 *
 * @implements CastsAttributes<CarbonImmutable, CarbonInterface|string>
 */
class DateOnly implements CastsAttributes
{
    public function get(Model $model, string $key, mixed $value, array $attributes): ?CarbonImmutable
    {
        return $value === null ? null : CarbonImmutable::parse($value)->startOfDay();
    }

    public function set(Model $model, string $key, mixed $value, array $attributes): ?string
    {
        if ($value === null || $value === '') {
            return null;
        }

        return ($value instanceof CarbonInterface ? $value : CarbonImmutable::parse($value))->toDateString();
    }
}
