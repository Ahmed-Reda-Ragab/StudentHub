<?php

namespace App\Services;

use App\Enums\SubscriptionStatus;
use App\Models\Scopes\OwnedByAuthenticatedUserScope;
use App\Models\User;
use App\Notifications\RenewalDueNotification;
use Carbon\CarbonInterface;

/**
 * Sends at most one "renewals due tomorrow" digest per user per day, triggered
 * on the first screen visit of the day — no cron, queue or scheduler involved.
 *
 * The live status lists never depend on this; it's an additional history layer.
 */
class NotificationSyncService
{
    /**
     * @return bool whether a sync ran (true) or was skipped because it already ran today
     */
    public function syncFor(User $user, ?CarbonInterface $today = null): bool
    {
        $today = ($today ?? today())->copy()->startOfDay();

        // Fast path: no query at all once today's sync is done.
        // (The column may be absent on an instance that was just created and never reloaded.)
        $notifiedOn = array_key_exists('notified_on', $user->getAttributes()) ? $user->notified_on : null;

        if ($notifiedOn?->isSameDay($today)) {
            return false;
        }

        // Atomic claim: only one concurrent request per user per day wins.
        $claimed = User::query()
            ->whereKey($user->getKey())
            ->where(fn ($q) => $q->whereNull('notified_on')->orWhere('notified_on', '<', $today->toDateString()))
            ->update(['notified_on' => $today->toDateString()]);

        $user->forceFill(['notified_on' => $today])->syncOriginalAttribute('notified_on');

        if ($claimed === 0) {
            return false;
        }

        $students = $user->students()
            ->withoutGlobalScope(OwnedByAuthenticatedUserScope::class)
            ->withStatus(SubscriptionStatus::DueTomorrow, $today)
            ->orderBy('number')
            ->get(['id', 'name', 'code']);

        if ($students->isNotEmpty()) {
            $user->notify(new RenewalDueNotification($students, $today->copy()->addDay()));
        }

        return true;
    }
}
