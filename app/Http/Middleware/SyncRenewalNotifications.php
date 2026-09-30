<?php

namespace App\Http\Middleware;

use App\Services\NotificationSyncService;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;
use Throwable;

/**
 * Lightweight daily sync on the main screens (students list, dashboard).
 * A failure here must never block the page — live lists don't depend on it.
 */
class SyncRenewalNotifications
{
    public function __construct(private readonly NotificationSyncService $sync) {}

    public function handle(Request $request, Closure $next): Response
    {
        if ($request->isMethod('GET') && $user = $request->user()) {
            try {
                $this->sync->syncFor($user);
            } catch (Throwable $e) {
                report($e);
            }
        }

        return $next($request);
    }
}
