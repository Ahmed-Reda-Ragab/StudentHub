<?php

namespace App\Enums;

use Carbon\CarbonImmutable;
use Carbon\CarbonInterface;
use Illuminate\Database\Eloquent\Builder;

/**
 * Single source of truth for the status rule — both the PHP evaluation
 * (resolve) and the SQL equivalent (constrain) live here, side by side.
 *
 *  today <  due - 1  → Active
 *  today == due - 1  → DueTomorrow
 *  today == due      → DueToday   (the due day itself is NOT expired)
 *  today >  due      → Expired
 */
enum SubscriptionStatus: string
{
    case Active = 'active';
    case DueTomorrow = 'due_tomorrow';
    case DueToday = 'due_today';
    case Expired = 'expired';

    public static function resolve(CarbonInterface $dueDate, CarbonInterface $today): self
    {
        $due = $dueDate->copy()->startOfDay();
        $today = $today->copy()->startOfDay();

        return match (true) {
            $today->gt($due) => self::Expired,
            $today->eq($due) => self::DueToday,
            $today->eq($due->copy()->subDay()) => self::DueTomorrow,
            default => self::Active,
        };
    }

    /**
     * Constrain a query on `next_renewal_date` to this status.
     */
    public function constrain(Builder $query, CarbonInterface $today, string $column = 'next_renewal_date'): Builder
    {
        $day = CarbonImmutable::parse($today->toDateString());
        $today = $day->toDateString();
        $tomorrow = $day->addDay()->toDateString();

        // Plain comparisons (not whereDate) so the (user_id, next_renewal_date) index is used.
        return match ($this) {
            self::Active => $query->where($column, '>', $tomorrow),
            self::DueTomorrow => $query->where($column, $tomorrow),
            self::DueToday => $query->where($column, $today),
            self::Expired => $query->where($column, '<', $today),
        };
    }

    /**
     * Statuses that require the user's attention (bell counter, notifications page).
     *
     * @return list<self>
     */
    public static function attention(): array
    {
        return [self::Expired, self::DueToday, self::DueTomorrow];
    }

    public function needsAttention(): bool
    {
        return $this !== self::Active;
    }

    public function label(): string
    {
        return __("subscriptions.status.{$this->value}");
    }

    public function emoji(): string
    {
        return match ($this) {
            self::Active => '🟢',
            self::DueTomorrow => '🟡',
            self::DueToday => '🟠',
            self::Expired => '🔴',
        };
    }

    public function icon(): string
    {
        return match ($this) {
            self::Active => 'check-circle',
            self::DueTomorrow => 'clock',
            self::DueToday => 'bell-alert',
            self::Expired => 'x-circle',
        };
    }

    /**
     * Tailwind classes for the status badge.
     */
    public function color(): string
    {
        return match ($this) {
            self::Active => 'bg-emerald-50 text-emerald-700 ring-emerald-600/20',
            self::DueTomorrow => 'bg-amber-50 text-amber-800 ring-amber-600/25',
            self::DueToday => 'bg-orange-50 text-orange-700 ring-orange-600/25',
            self::Expired => 'bg-red-50 text-red-700 ring-red-600/20',
        };
    }
}
