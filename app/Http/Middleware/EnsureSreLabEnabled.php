<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * /sre-lab/* does not exist unless SRE_LAB_ENABLED=true, and requires
 * X-Lab-Token when SRE_LAB_TOKEN is set.
 */
class EnsureSreLabEnabled
{
    public function handle(Request $request, Closure $next): Response
    {
        abort_unless(config('sre_lab.enabled'), Response::HTTP_NOT_FOUND);

        $token = config('sre_lab.token');

        if (filled($token) && ! hash_equals((string) $token, (string) $request->header('X-Lab-Token'))) {
            abort(Response::HTTP_FORBIDDEN, 'Invalid or missing X-Lab-Token.');
        }

        return $next($request);
    }
}
