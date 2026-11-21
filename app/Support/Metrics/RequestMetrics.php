<?php

namespace App\Support\Metrics;

use Prometheus\CollectorRegistry;
use Prometheus\RenderTextFormat;
use Prometheus\Storage\Adapter;
use Prometheus\Storage\APCng;
use Prometheus\Storage\InMemory;

/**
 * RED metrics (Rate, Errors, Duration) in Prometheus format.
 *
 * With the APCu adapter the counters live in shared memory, so every PHP-FPM
 * worker of one container adds to the same numbers and Prometheus scrapes
 * each container (pod / task) separately.
 */
class RequestMetrics
{
    /** Seconds; tuned around the 300ms / 1s latency SLO thresholds used in the lab. */
    public const BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.3, 0.5, 1, 2.5, 5, 10];

    public function __construct(
        private readonly CollectorRegistry $registry,
        private readonly string $namespace,
    ) {}

    public static function storage(string $driver): Adapter
    {
        if ($driver === 'apcu' && function_exists('apcu_enabled') && apcu_enabled()) {
            return new APCng;
        }

        return new InMemory;
    }

    public function observe(string $method, string $route, int $status, float $seconds): void
    {
        $this->registry
            ->getOrRegisterCounter($this->namespace, 'http_requests_total', 'HTTP requests handled by the app.', ['method', 'route', 'status'])
            ->inc([$method, $route, (string) $status]);

        $this->registry
            ->getOrRegisterHistogram($this->namespace, 'http_request_duration_seconds', 'HTTP request latency in seconds.', ['method', 'route'], self::BUCKETS)
            ->observe($seconds, [$method, $route]);
    }

    /**
     * @param  array{version: string, color: string}  $release
     */
    public function render(array $release): string
    {
        $this->registry
            ->getOrRegisterGauge($this->namespace, 'app_info', 'The release currently running in this instance.', ['version', 'color'])
            ->set(1, [$release['version'], $release['color']]);

        return (new RenderTextFormat)->render($this->registry->getMetricFamilySamples());
    }
}
