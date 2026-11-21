<?php

namespace App\Http\Controllers\Health;

use App\Http\Controllers\Controller;
use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\DB;
use Symfony\Component\HttpFoundation\Response;
use Throwable;

/**
 * Readiness probe: "can this instance serve traffic right now?"
 *
 * Unlike liveness (/up, process is alive), readiness checks dependencies (DB).
 * Load balancers / Kubernetes stop routing to an instance that fails it, but
 * do NOT restart it. Registered outside the "web" group: no session row per check.
 */
class ReadinessController extends Controller
{
    public function __invoke(): JsonResponse
    {
        if (is_file((string) config('sre_lab.unready_flag'))) {
            return $this->unready('manually drained (unready flag present)');
        }

        if (config('sre_lab.enabled') && config('sre_lab.faults.unhealthy')) {
            return $this->unready('fault injection: SRE_FAULT_UNHEALTHY');
        }

        try {
            DB::select('select 1');
        } catch (Throwable) {
            return $this->unready('database unreachable', ['database' => 'fail']);
        }

        return response()->json([
            'status' => 'ready',
            'checks' => ['database' => 'ok'],
            ...$this->release(),
        ]);
    }

    /**
     * @param  array<string, string>  $checks
     */
    private function unready(string $reason, array $checks = []): JsonResponse
    {
        return response()->json([
            'status' => 'unready',
            'reason' => $reason,
            'checks' => $checks,
            ...$this->release(),
        ], Response::HTTP_SERVICE_UNAVAILABLE);
    }

    /**
     * @return array{version: string, color: string}
     */
    private function release(): array
    {
        return [
            'version' => (string) config('sre_lab.release.version'),
            'color' => (string) config('sre_lab.release.color'),
        ];
    }
}
