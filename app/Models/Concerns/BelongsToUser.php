<?php

namespace App\Models\Concerns;

use App\Models\Scopes\OwnedByAuthenticatedUserScope;
use App\Models\User;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Auth;

/**
 * Multi-tenant isolation: every query is scoped to the signed-in user and
 * user_id is filled automatically on create. Route model binding therefore
 * returns 404 for records owned by someone else.
 */
trait BelongsToUser
{
    public static function bootBelongsToUser(): void
    {
        static::addGlobalScope(new OwnedByAuthenticatedUserScope);

        static::creating(function (self $model): void {
            if (! $model->user_id && Auth::hasUser()) {
                $model->user_id = Auth::id();
            }
        });
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }
}
