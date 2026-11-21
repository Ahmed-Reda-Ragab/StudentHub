<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class MetricsTest extends TestCase
{
    use RefreshDatabase;

    public function test_metrics_endpoint_is_404_when_disabled(): void
    {
        config(['sre_lab.metrics.enabled' => false]);

        $this->get('/metrics')->assertNotFound();
    }

    public function test_requests_are_counted_with_route_and_status_labels(): void
    {
        config(['sre_lab.metrics.enabled' => true, 'sre_lab.release.version' => 'abc1234', 'sre_lab.release.color' => 'green']);

        $this->get('/login')->assertOk();
        $this->get('/does-not-exist')->assertNotFound();

        $this->get('/metrics')
            ->assertOk()
            ->assertHeader('Content-Type', 'text/plain; version=0.0.4; charset=utf-8')
            ->assertSee('student_app_http_requests_total{method="GET",route="login",status="200"} 1', false)
            ->assertSee('student_app_http_requests_total{method="GET",route="unmatched",status="404"} 1', false)
            ->assertSee('student_app_http_request_duration_seconds_bucket{method="GET",route="login"', false)
            ->assertSee('student_app_app_info{version="abc1234",color="green"} 1', false)
            ->assertDontSee('route="metrics"', false);
    }

    public function test_metrics_token_is_required_when_configured(): void
    {
        config(['sre_lab.metrics.enabled' => true, 'sre_lab.metrics.token' => 'scrape-me']);

        $this->get('/metrics')->assertForbidden();
        $this->withToken('scrape-me')->get('/metrics')->assertOk();
    }
}
