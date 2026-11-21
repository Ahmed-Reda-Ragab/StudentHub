<?php

namespace App\Http\Controllers;

use App\Support\Chance;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\File;

/**
 * Load-testing / chaos endpoints for the DevOps-SRE lab (docs/devops).
 * Reachable only when SRE_LAB_ENABLED=true (see EnsureSreLabEnabled);
 * every input is clamped to config('sre_lab.limits').
 */
class SreLabController extends Controller
{
    /**
     * Cheapest possible request: no DB, no session. Baseline for latency.
     */
    public function ping(): JsonResponse
    {
        return response()->json(['status' => 'ok', 'time' => now()->toIso8601String()]);
    }

    /**
     * Which release/instance answered — used to watch blue/green & canary traffic split.
     */
    public function version(): JsonResponse
    {
        return response()->json([
            'version' => config('sre_lab.release.version'),
            'color' => config('sre_lab.release.color'),
            'hostname' => gethostname(),
            'php' => PHP_VERSION,
            'laravel' => app()->version(),
        ]);
    }

    /**
     * Injected latency: ?ms=200&jitter=100.
     */
    public function latency(Request $request): JsonResponse
    {
        $max = (int) config('sre_lab.limits.latency_ms');
        $ms = self::clamp($request->integer('ms', 200), 0, $max);
        $jitter = self::clamp($request->integer('jitter'), 0, $max);
        $slept = min($ms + ($jitter > 0 ? random_int(0, $jitter) : 0), $max);

        usleep($slept * 1000);

        return response()->json(['slept_ms' => $slept]);
    }

    /**
     * Probabilistic failure: ?rate=0.1&code=503 (defaults: always, 500).
     */
    public function fail(Request $request): JsonResponse
    {
        $rate = max(0.0, min(1.0, $request->float('rate', 1.0)));
        $code = self::clamp($request->integer('code', 500), 500, 599);

        if (Chance::roll($rate)) {
            return response()->json(['status' => 'error', 'injected' => true, 'code' => $code], $code);
        }

        return response()->json(['status' => 'ok', 'injected' => false]);
    }

    /**
     * Burns CPU for ?ms=200 — drives ASG / ECS / HPA CPU-based autoscaling.
     */
    public function cpu(Request $request): JsonResponse
    {
        $ms = self::clamp($request->integer('ms', 200), 1, (int) config('sre_lab.limits.cpu_ms'));
        $deadline = hrtime(true) + $ms * 1_000_000;
        $hash = 'student-app';
        $iterations = 0;

        while (hrtime(true) < $deadline) {
            $hash = hash('sha256', $hash);
            $iterations++;
        }

        return response()->json(['burned_ms' => $ms, 'iterations' => $iterations]);
    }

    /**
     * Allocates ?mb=32 for ?hold_ms=100 — explores memory limits / OOM kills.
     */
    public function memory(Request $request): JsonResponse
    {
        $mb = self::clamp($request->integer('mb', 32), 1, (int) config('sre_lab.limits.memory_mb'));
        $holdMs = self::clamp($request->integer('hold_ms', 100), 0, (int) config('sre_lab.limits.hold_ms'));

        $block = str_repeat('x', $mb * 1024 * 1024);
        usleep($holdMs * 1000);
        $peakMb = round(memory_get_peak_usage(true) / 1_048_576, 1);
        unset($block);

        return response()->json(['allocated_mb' => $mb, 'held_ms' => $holdMs, 'peak_mb' => $peakMb]);
    }

    /**
     * Realistic indexed read: latest ?limit=50 students across all tenants.
     */
    public function db(Request $request): JsonResponse
    {
        $limit = self::clamp($request->integer('limit', 50), 1, (int) config('sre_lab.limits.db_rows'));
        $startedAt = hrtime(true);

        $rows = DB::table('students')
            ->whereNull('deleted_at')
            ->orderByDesc('id')
            ->limit($limit)
            ->get(['id', 'name', 'section', 'next_renewal_date']);

        return response()->json([
            'rows' => $rows->count(),
            'query_ms' => self::elapsedMs($startedAt),
        ]);
    }

    /**
     * Expensive aggregate (full scan + group by) — finds the DB bottleneck under load.
     */
    public function dbHeavy(): JsonResponse
    {
        $startedAt = hrtime(true);
        $today = now()->toDateString();

        $revenue = DB::table('subscriptions')
            ->selectRaw('user_id, count(*) as entries, sum(price) as revenue, sum(commission) as commission')
            ->groupBy('user_id')
            ->orderByDesc('revenue')
            ->limit(20)
            ->get();

        $status = DB::table('students')
            ->whereNull('deleted_at')
            ->selectRaw(
                'sum(case when next_renewal_date < ? then 1 else 0 end) as expired, '
                .'sum(case when next_renewal_date = ? then 1 else 0 end) as due_today, '
                .'sum(case when next_renewal_date > ? then 1 else 0 end) as active',
                [$today, $today, $today],
            )
            ->first();

        return response()->json([
            'tenants' => $revenue->count(),
            'status' => [
                'expired' => (int) ($status->expired ?? 0),
                'due_today' => (int) ($status->due_today ?? 0),
                'active' => (int) ($status->active ?? 0),
            ],
            'query_ms' => self::elapsedMs($startedAt),
        ]);
    }

    /**
     * Makes THIS instance fail /ready so the load balancer drains it.
     */
    public function markUnready(): JsonResponse
    {
        File::put((string) config('sre_lab.unready_flag'), now()->toIso8601String());

        return response()->json(['status' => 'unready', 'hostname' => gethostname()]);
    }

    public function markReady(): JsonResponse
    {
        File::delete((string) config('sre_lab.unready_flag'));

        return response()->json(['status' => 'ready', 'hostname' => gethostname()]);
    }

    private static function clamp(int $value, int $min, int $max): int
    {
        return max($min, min($max, $value));
    }

    private static function elapsedMs(int|float $startedAt): float
    {
        return round((hrtime(true) - $startedAt) / 1e6, 2);
    }
}
