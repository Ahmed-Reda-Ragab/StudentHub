<?php

namespace App\Http\Controllers;

use App\Http\Requests\UpdateSubscriptionRequest;
use App\Models\Subscription;
use App\Services\SubscriptionService;
use Illuminate\Http\RedirectResponse;
use Illuminate\Support\Facades\Gate;
use Illuminate\Validation\ValidationException;

class SubscriptionController extends Controller
{
    public function update(UpdateSubscriptionRequest $request, Subscription $subscription, SubscriptionService $subscriptions): RedirectResponse
    {
        try {
            $subscriptions->update(
                $subscription,
                $request->startDate(),
                price: $request->validated('price'),
                commission: $request->validated('commission'),
                note: $request->validated('note'),
            );
        } catch (ValidationException $e) {
            throw $e->errorBag('subscription');
        }

        return to_route('students.show', $subscription->student_id)
            ->with('toast', ['type' => 'success', 'message' => __('subscriptions.messages.updated')]);
    }

    public function destroy(Subscription $subscription, SubscriptionService $subscriptions): RedirectResponse
    {
        Gate::authorize('delete', $subscription);

        try {
            $subscriptions->delete($subscription);
        } catch (ValidationException $e) {
            return back(fallback: route('students.show', $subscription->student_id))
                ->with('toast', ['type' => 'error', 'message' => collect($e->errors())->flatten()->first()]);
        }

        return to_route('students.show', $subscription->student_id)
            ->with('toast', ['type' => 'success', 'message' => __('subscriptions.messages.deleted')]);
    }
}
