<?php

namespace App\Http\Controllers;

use App\Support\Metrics\RequestMetrics;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Prometheus\RenderTextFormat;

/**
 * Prometheus scrape endpoint (METRICS_ENABLED=true; optional METRICS_TOKEN bearer).
 * Block it at the load balancer / ingress — it is meant for the scraper only.
 */
class MetricsController extends Controller
{
    public function __invoke(Request $request, RequestMetrics $metrics): Response
    {
        abort_unless(config('sre_lab.metrics.enabled'), Response::HTTP_NOT_FOUND);

        $token = config('sre_lab.metrics.token');

        if (filled($token) && ! hash_equals((string) $token, (string) $request->bearerToken())) {
            abort(Response::HTTP_FORBIDDEN);
        }

        return response($metrics->render([
            'version' => (string) config('sre_lab.release.version'),
            'color' => (string) config('sre_lab.release.color'),
        ]), Response::HTTP_OK, ['Content-Type' => RenderTextFormat::MIME_TYPE]);
    }
}
