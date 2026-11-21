<?php

use App\Http\Controllers\Health\ReadinessController;
use App\Http\Controllers\MetricsController;
use App\Http\Middleware\EnsureSreLabEnabled;
use App\Http\Middleware\InjectFaults;
use App\Http\Middleware\PreventDuplicateSubmissions;
use App\Http\Middleware\RecordRequestMetrics;
use App\Http\Middleware\SyncRenewalNotifications;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
        // Infra endpoints live outside the "web" group: no session row, no CSRF, cheap to call.
        then: function (): void {
            Route::get('/ready', ReadinessController::class)->name('health.ready');
            Route::get('/metrics', MetricsController::class)->name('metrics');

            Route::middleware(EnsureSreLabEnabled::class)
                ->prefix('sre-lab')
                ->name('sre-lab.')
                ->group(__DIR__.'/../routes/sre-lab.php');
        },
    )
    ->withMiddleware(function (Middleware $middleware): void {
        // Behind ALB / nginx / ingress: TLS ends at the proxy, so trust X-Forwarded-Proto
        // for correct https:// URLs and redirects. The container's nginx already
        // restores the client IP (real_ip, TRUSTED_PROXY=local).
        $middleware->trustProxies(at: '*', headers: Request::HEADER_X_FORWARDED_PROTO);

        $middleware->append(RecordRequestMetrics::class);

        $middleware->web(append: [
            InjectFaults::class,
            PreventDuplicateSubmissions::class,
        ]);

        $middleware->alias([
            'sync.notifications' => SyncRenewalNotifications::class,
        ]);

        $middleware->redirectGuestsTo(fn () => route('login'));
        $middleware->redirectUsersTo(fn () => route('students.index'));
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        $exceptions->shouldRenderJsonWhen(
            fn (Request $request) => $request->is('api/*', 'sre-lab/*', 'ready') || $request->expectsJson(),
        );
    })->create();
