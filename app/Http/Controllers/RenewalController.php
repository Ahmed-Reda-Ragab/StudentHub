<?php

namespace App\Http\Controllers;

use App\Http\Requests\RenewStudentRequest;
use App\Models\Student;
use App\Services\SubscriptionService;
use Illuminate\Http\RedirectResponse;
use Illuminate\Validation\ValidationException;

/**
 * Append-only: renewals can be created, never updated or deleted (no routes for it).
 */
class RenewalController extends Controller
{
    public function store(RenewStudentRequest $request, Student $student, SubscriptionService $subscriptions): RedirectResponse
    {
        try {
            $subscriptions->renew(
                $student,
                $request->renewalDate(),
                price: $request->validated('price'),
                commission: $request->validated('commission'),
                note: $request->validated('note'),
            );
        } catch (ValidationException $e) {
            throw $e->errorBag('renewal');
        }

        return back(fallback: route('students.show', $student))
            ->with('toast', ['type' => 'success', 'message' => __('subscriptions.messages.renewed', [
                'name' => $student->name,
                'date' => $student->next_renewal_date->format('d/m/Y'),
            ])]);
    }
}
