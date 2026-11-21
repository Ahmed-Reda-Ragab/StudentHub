<?php

namespace Tests\Feature\SreLab;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class FaultInjectionTest extends TestCase
{
    use RefreshDatabase;

    public function test_error_rate_fault_breaks_normal_pages_when_the_lab_is_enabled(): void
    {
        config(['sre_lab.enabled' => true, 'sre_lab.faults.error_rate' => 1.0]);

        $this->get('/login')->assertStatus(500)->assertHeader('X-SRE-Fault', 'error-rate');
    }

    public function test_faults_are_ignored_while_the_lab_is_disabled(): void
    {
        config(['sre_lab.enabled' => false, 'sre_lab.faults.error_rate' => 1.0, 'sre_lab.faults.unhealthy' => true]);

        $this->get('/login')->assertOk();
        $this->get('/up')->assertOk();
        $this->getJson('/ready')->assertOk();
    }

    public function test_a_degraded_release_still_passes_health_checks(): void
    {
        config(['sre_lab.enabled' => true, 'sre_lab.faults.error_rate' => 1.0]);

        // Only metric-based analysis catches this kind of bad release.
        $this->get('/up')->assertOk();
        $this->getJson('/ready')->assertOk();
    }

    public function test_unhealthy_fault_fails_liveness_and_readiness(): void
    {
        config(['sre_lab.enabled' => true, 'sre_lab.faults.unhealthy' => true]);

        $this->get('/up')->assertStatus(500);
        $this->getJson('/ready')->assertStatus(503)->assertJsonPath('reason', 'fault injection: SRE_FAULT_UNHEALTHY');
    }

    public function test_latency_fault_is_capped(): void
    {
        config(['sre_lab.enabled' => true, 'sre_lab.faults.latency_ms' => 60_000, 'sre_lab.limits.latency_ms' => 1]);

        $startedAt = microtime(true);
        $this->get('/login')->assertOk();

        $this->assertLessThan(5, microtime(true) - $startedAt);
    }
}
