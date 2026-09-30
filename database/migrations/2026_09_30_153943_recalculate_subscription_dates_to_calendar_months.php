<?php

use Carbon\CarbonImmutable;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;

/**
 * Switches existing data from a fixed 30-day period to calendar months:
 *   subscriptions.ends_on        = start_date + 1 month − 1 day (last covered day)
 *   students.next_renewal_date   = last_subscription_date + 1 month
 *
 * Plain query builder (not models) so the append-only guard on Subscription and
 * future model changes can't interfere with this one-off data fix.
 */
return new class extends Migration
{
    public function up(): void
    {
        $this->recalculate(fn (CarbonImmutable $start) => $start->addMonthNoOverflow());
    }

    public function down(): void
    {
        $this->recalculate(fn (CarbonImmutable $start) => $start->addDays(30), endsOnIsRenewalDate: true);
    }

    /**
     * @param  Closure(CarbonImmutable): CarbonImmutable  $nextRenewal
     */
    private function recalculate(Closure $nextRenewal, bool $endsOnIsRenewalDate = false): void
    {
        DB::transaction(function () use ($nextRenewal, $endsOnIsRenewalDate) {
            DB::table('subscriptions')->select(['id', 'start_date'])->orderBy('id')
                ->chunkById(500, function ($rows) use ($nextRenewal, $endsOnIsRenewalDate) {
                    foreach ($rows as $row) {
                        $next = $nextRenewal(CarbonImmutable::parse($row->start_date));

                        DB::table('subscriptions')->where('id', $row->id)->update([
                            'ends_on' => ($endsOnIsRenewalDate ? $next : $next->subDay())->toDateString(),
                        ]);
                    }
                });

            DB::table('students')->select(['id', 'last_subscription_date'])->orderBy('id')
                ->chunkById(500, function ($rows) use ($nextRenewal) {
                    foreach ($rows as $row) {
                        DB::table('students')->where('id', $row->id)->update([
                            'next_renewal_date' => $nextRenewal(CarbonImmutable::parse($row->last_subscription_date))->toDateString(),
                        ]);
                    }
                });
        });
    }
};
