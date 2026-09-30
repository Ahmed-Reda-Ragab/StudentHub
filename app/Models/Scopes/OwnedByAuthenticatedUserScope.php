<?php

namespace App\Models\Scopes;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Scope;
use Illuminate\Support\Facades\Auth;

class OwnedByAuthenticatedUserScope implements Scope
{
    public function apply(Builder $builder, Model $model): void
    {
        // Outside an authenticated context (console, seeders, queued code) no filter is applied;
        // those callers must scope explicitly by user.
        if (Auth::hasUser()) {
            $builder->where($model->qualifyColumn('user_id'), Auth::id());
        }
    }
}
