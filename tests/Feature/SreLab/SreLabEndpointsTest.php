<?php

namespace Tests\Feature\SreLab;

use App\Models\Student;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\File;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\TestCase;

class SreLabEndpointsTest extends TestCase
{
    use RefreshDatabase;

    protected function tearDown(): void
    {
        File::delete((string) config('sre_lab.unready_flag'));

        parent::tearDown();
    }

    /**
     * @return array<string, array{string, string}>
     */
    public static function endpoints(): array
    {
        return [
            'ping' => ['get', '/sre-lab/ping'],
            'version' => ['get', '/sre-lab/version'],
            'latency' => ['get', '/sre-lab/latency?ms=0'],
            'error' => ['get', '/sre-lab/error?rate=0'],
            'cpu' => ['get', '/sre-lab/cpu?ms=1'],
            'memory' => ['get', '/sre-lab/memory?mb=1&hold_ms=0'],
            'db' => ['get', '/sre-lab/db'],
            'db heavy' => ['get', '/sre-lab/db/heavy'],
            'unready' => ['post', '/sre-lab/unready'],
            'ready' => ['post', '/sre-lab/ready'],
        ];
    }

    #[DataProvider('endpoints')]
    public function test_every_endpoint_is_404_when_the_lab_is_disabled(string $method, string $uri): void
    {
        config(['sre_lab.enabled' => false]);

        $this->json($method, $uri)->assertNotFound();
    }

    #[DataProvider('endpoints')]
    public function test_every_endpoint_answers_when_the_lab_is_enabled(string $method, string $uri): void
    {
        config(['sre_lab.enabled' => true]);

        $this->json($method, $uri)->assertOk();
    }

    public function test_the_lab_token_is_required_when_configured(): void
    {
        config(['sre_lab.enabled' => true, 'sre_lab.token' => 'secret']);

        $this->getJson('/sre-lab/ping')->assertForbidden();
        $this->getJson('/sre-lab/ping', ['X-Lab-Token' => 'wrong'])->assertForbidden();
        $this->getJson('/sre-lab/ping', ['X-Lab-Token' => 'secret'])->assertOk()->assertJson(['status' => 'ok']);
    }

    public function test_lab_endpoints_do_not_start_a_session(): void
    {
        config(['sre_lab.enabled' => true]);

        $this->getJson('/sre-lab/ping')->assertOk()->assertCookieMissing(config('session.cookie'));
    }

    public function test_version_reports_the_running_release(): void
    {
        config(['sre_lab.enabled' => true, 'sre_lab.release.version' => 'abc1234', 'sre_lab.release.color' => 'green']);

        $this->getJson('/sre-lab/version')
            ->assertOk()
            ->assertJson(['version' => 'abc1234', 'color' => 'green', 'hostname' => gethostname()]);
    }

    public function test_latency_is_capped_by_the_configured_limit(): void
    {
        config(['sre_lab.enabled' => true, 'sre_lab.limits.latency_ms' => 5]);

        $this->getJson('/sre-lab/latency?ms=100000&jitter=100000')
            ->assertOk()
            ->assertJsonPath('slept_ms', fn (int $slept) => $slept >= 0 && $slept <= 5);
    }

    public function test_error_endpoint_returns_the_requested_status_when_the_roll_hits(): void
    {
        config(['sre_lab.enabled' => true]);

        $this->getJson('/sre-lab/error?rate=1&code=503')->assertStatus(503)->assertJson(['injected' => true]);
        $this->getJson('/sre-lab/error?rate=1&code=200')->assertStatus(500);
        $this->getJson('/sre-lab/error?rate=0')->assertOk()->assertJson(['injected' => false]);
    }

    public function test_cpu_and_memory_are_capped(): void
    {
        config(['sre_lab.enabled' => true, 'sre_lab.limits.cpu_ms' => 2, 'sre_lab.limits.memory_mb' => 2]);

        $this->getJson('/sre-lab/cpu?ms=999999')->assertOk()->assertJsonPath('burned_ms', 2);
        $this->getJson('/sre-lab/memory?mb=999999&hold_ms=0')->assertOk()->assertJsonPath('allocated_mb', 2);
    }

    public function test_db_endpoints_read_real_data(): void
    {
        config(['sre_lab.enabled' => true]);

        Student::factory()->for(User::factory())->count(3)->create();

        $this->getJson('/sre-lab/db?limit=2')->assertOk()->assertJsonPath('rows', 2);
        $this->getJson('/sre-lab/db/heavy')->assertOk()->assertJsonStructure(['tenants', 'status' => ['expired', 'due_today', 'active'], 'query_ms']);
    }

    public function test_unready_toggle_drains_and_restores_this_instance(): void
    {
        config(['sre_lab.enabled' => true]);

        $this->getJson('/ready')->assertOk();

        $this->postJson('/sre-lab/unready')->assertOk();
        $this->getJson('/ready')->assertStatus(503)->assertJsonPath('status', 'unready');

        $this->postJson('/sre-lab/ready')->assertOk();
        $this->getJson('/ready')->assertOk()->assertJsonPath('status', 'ready');
    }
}
