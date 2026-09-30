<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

/**
 * Idempotency for HTML forms: each form carries a one-off `_submission_token` (UUID).
 * A replay of the same token within the TTL is not executed again — the user is sent
 * to the same result (redirect target) as the first submission.
 *
 * Complements (never replaces) the DB unique constraints.
 */
class PreventDuplicateSubmissions
{
    public const FIELD = '_submission_token';

    private const PENDING = '__pending__';

    public function handle(Request $request, Closure $next): Response
    {
        $token = $request->input(self::FIELD);

        if ($request->isMethodSafe() || ! $request->user() || ! is_string($token) || ! Str::isUuid($token)) {
            return $next($request);
        }

        $key = sprintf('submission:%d:%s', $request->user()->getKey(), $token);
        $ttl = (int) config('subscriptions.submission_token_ttl', 60);

        if (! Cache::add($key, self::PENDING, $ttl)) {
            $previous = Cache::get($key);

            if (is_string($previous) && $previous !== self::PENDING) {
                return redirect()->to($previous);
            }

            return back()->with('toast', ['type' => 'info', 'message' => __('app.messages.already_submitted')]);
        }

        $response = $next($request);

        $succeeded = $response instanceof RedirectResponse
            && $response->getStatusCode() < 400
            && ! $request->session()->has('errors');

        // Failed attempts release the token so the corrected form can be re-submitted.
        $succeeded
            ? Cache::put($key, $response->getTargetUrl(), $ttl)
            : Cache::forget($key);

        return $response;
    }
}
