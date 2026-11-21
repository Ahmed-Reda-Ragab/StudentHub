<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\File;
use Tests\TestCase;

class HealthCheckTest extends TestCase
{
    use RefreshDatabase;

    protected function tearDown(): void
    {
        File::delete((string) config('sre_lab.unready_flag'));

        parent::tearDown();
    }

    public function test_liveness_is_up(): void
    {
        $this->get('/up')->assertOk();
    }

    public function test_readiness_checks_the_database_and_reports_the_release(): void
    {
        config(['sre_lab.release.version' => 'abc1234', 'sre_lab.release.color' => 'blue']);

        $this->getJson('/ready')
            ->assertOk()
            ->assertExactJson([
                'status' => 'ready',
                'checks' => ['database' => 'ok'],
                'version' => 'abc1234',
                'color' => 'blue',
            ]);
    }

    public function test_an_unready_flag_drains_the_instance_even_with_the_lab_disabled(): void
    {
        File::put((string) config('sre_lab.unready_flag'), 'manual');

        $this->getJson('/ready')
            ->assertStatus(503)
            ->assertJsonPath('reason', 'manually drained (unready flag present)');
    }

    public function test_health_endpoints_do_not_start_a_session(): void
    {
        $this->getJson('/ready')->assertCookieMissing(config('session.cookie'));
        $this->get('/up')->assertCookieMissing(config('session.cookie'));
    }
}
