<?php

namespace App\Http\Controllers;

use App\Enums\SubscriptionStatus;
use App\Models\Student;
use Illuminate\Http\Request;
use Illuminate\View\View;

/**
 * Live renewal lists computed from the DB on every request (independent of the
 * stored database notifications, which are only a history layer).
 */
class NotificationController extends Controller
{
    public function index(Request $request): View
    {
        $today = today();

        $groups = collect([SubscriptionStatus::Expired, SubscriptionStatus::DueToday, SubscriptionStatus::DueTomorrow])
            ->mapWithKeys(fn (SubscriptionStatus $status) => [
                $status->value => Student::query()
                    ->withStatus($status, $today)
                    ->orderBy('next_renewal_date')
                    ->orderBy('number')
                    ->get(),
            ]);

        $history = $request->user()->notifications()->latest()->limit(10)->get();

        $request->user()->unreadNotifications()->update(['read_at' => now()]);

        return view('notifications.index', [
            'groups' => $groups,
            'history' => $history,
        ]);
    }
}
