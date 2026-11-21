<?php

namespace App\Http\Middleware;

use App\Support\Chance;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Simulates a degraded ("bad") release on normal web pages, driven only by env:
 * SRE_FAULT_LATENCY_MS and SRE_FAULT_ERROR_RATE. Health checks keep passing on
 * purpose — only metric-based analysis (canary, burn-rate alarms) catches it.
 */
class InjectFaults
{
    public function handle(Request $request, Closure $next): Response
    {
        if (! config('sre_lab.enabled')) {
            return $next($request);
        }

        $latency = min((int) config('sre_lab.faults.latency_ms'), (int) config('sre_lab.limits.latency_ms'));

        if ($latency > 0) {
            usleep($latency * 1000);
        }

        if (Chance::roll((float) config('sre_lab.faults.error_rate'))) {
            abort(Response::HTTP_INTERNAL_SERVER_ERROR, 'SRE lab: injected fault.', ['X-SRE-Fault' => 'error-rate']);
        }

        return $next($request);
    }
}
