<?php

namespace App\Services;

use App\Enums\SubscriptionType;
use App\Models\Subscription;
use Carbon\CarbonInterface;
use Illuminate\Contracts\Pagination\LengthAwarePaginator;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;

/**
 * Money collected in a date range, based on each subscription's start date
 * (the day it was paid: initial subscription or renewal).
 * Scoped to the signed-in user by the BelongsToUser global scope.
 */
class RevenueReportService
{
    /**
     * @return array{count: int, initial_count: int, renewal_count: int, price_total: float, commission_total: float}
     */
    public function totals(CarbonInterface $from, CarbonInterface $to): array
    {
        $row = $this->inRange($from, $to)
            ->toBase()
            ->selectRaw('count(*) as total')
            ->selectRaw('coalesce(sum(case when type = ? then 1 else 0 end), 0) as initial_count', [SubscriptionType::Initial->value])
            ->selectRaw('coalesce(sum(case when type = ? then 1 else 0 end), 0) as renewal_count', [SubscriptionType::Renewal->value])
            ->selectRaw('coalesce(sum(price), 0) as price_total')
            ->selectRaw('coalesce(sum(commission), 0) as commission_total')
            ->first();

        return [
            'count' => (int) $row->total,
            'initial_count' => (int) $row->initial_count,
            'renewal_count' => (int) $row->renewal_count,
            'price_total' => (float) $row->price_total,
            'commission_total' => (float) $row->commission_total,
        ];
    }

    /**
     * One row per day that had payments, newest first.
     *
     * @return Collection<int, object{day: string, count: int, price_total: float, commission_total: float}>
     */
    public function daily(CarbonInterface $from, CarbonInterface $to): Collection
    {
        return $this->inRange($from, $to)
            ->toBase()
            ->selectRaw('start_date as day, count(*) as count, sum(price) as price_total, sum(commission) as commission_total')
            ->groupBy('start_date')
            ->orderByDesc('start_date')
            ->get();
    }

    public function entries(CarbonInterface $from, CarbonInterface $to, int $perPage = 25): LengthAwarePaginator
    {
        return $this->inRange($from, $to)
            ->with('student:id,number,name,code')
            ->orderByDesc('start_date')
            ->orderByDesc('id')
            ->paginate($perPage)
            ->withQueryString();
    }

    private function inRange(CarbonInterface $from, CarbonInterface $to): Builder
    {
        return Subscription::query()->whereBetween('start_date', [$from->toDateString(), $to->toDateString()]);
    }
}
