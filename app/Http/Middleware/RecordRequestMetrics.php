<?php

namespace App\Http\Middleware;

use App\Support\Metrics\RequestMetrics;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Global middleware: counts every request and its latency (when METRICS_ENABLED=true).
 * The route label is the route name (or URI pattern) to keep cardinality low.
 */
class RecordRequestMetrics
{
    public function __construct(private readonly RequestMetrics $metrics) {}

    public function handle(Request $request, Closure $next): Response
    {
        if (! config('sre_lab.metrics.enabled')) {
            return $next($request);
        }

        $startedAt = hrtime(true);

        $response = $next($request);

        $route = $request->route();

        if ($route?->getName() !== 'metrics') {
            $this->metrics->observe(
                method: $request->getMethod(),
                route: $route ? ($route->getName() ?? $route->uri()) : 'unmatched',
                status: $response->getStatusCode(),
                seconds: (hrtime(true) - $startedAt) / 1e9,
            );
        }

        return $response;
    }
}
