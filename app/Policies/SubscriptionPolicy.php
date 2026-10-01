<?php

namespace App\Policies;

use App\Models\Subscription;
use App\Models\User;

/**
 * Defense in depth: the BelongsToUser global scope already 404s foreign records.
 */
class SubscriptionPolicy
{
    public function update(User $user, Subscription $subscription): bool
    {
        return $subscription->user_id === $user->id;
    }

    public function delete(User $user, Subscription $subscription): bool
    {
        return $subscription->user_id === $user->id;
    }
}
