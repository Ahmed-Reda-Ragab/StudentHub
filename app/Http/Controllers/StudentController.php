<?php

namespace App\Http\Controllers;

use App\Enums\SubscriptionStatus;
use App\Http\Requests\StoreStudentRequest;
use App\Http\Requests\UpdateStudentRequest;
use App\Models\Student;
use App\Services\SubscriptionService;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Gate;
use Illuminate\View\View;

class StudentController extends Controller
{
    public function index(Request $request): View
    {
        $term = trim((string) $request->query('q', ''));
        $status = SubscriptionStatus::tryFrom((string) $request->query('status'));

        $query = Student::query()->search($term);

        $counts = Student::statusCounts($query);

        $students = $query
            ->when($status, fn ($q) => $q->withStatus($status))
            ->orderBy('number')
            ->paginate(config('subscriptions.per_page'))
            ->withQueryString();

        return view('students.index', [
            'students' => $students,
            'counts' => $counts,
            'term' => $term,
            'status' => $status,
        ]);
    }

    public function create(): View
    {
        return view('students.create');
    }

    public function store(StoreStudentRequest $request, SubscriptionService $subscriptions): RedirectResponse
    {
        $student = $subscriptions->addStudent($request->user(), $request->validated());

        return to_route('students.show', $student)
            ->with('toast', ['type' => 'success', 'message' => __('students.messages.created')]);
    }

    public function show(Student $student): View
    {
        Gate::authorize('view', $student);

        $student->load('subscriptions');

        return view('students.show', ['student' => $student]);
    }

    public function edit(Student $student): View
    {
        Gate::authorize('update', $student);

        return view('students.edit', ['student' => $student]);
    }

    public function update(UpdateStudentRequest $request, Student $student): RedirectResponse
    {
        $student->update($request->validated());

        return to_route('students.show', $student)
            ->with('toast', ['type' => 'success', 'message' => __('students.messages.updated')]);
    }

    public function destroy(Student $student): RedirectResponse
    {
        Gate::authorize('delete', $student);

        $student->delete();

        return to_route('students.index')
            ->with('toast', ['type' => 'success', 'message' => __('students.messages.deleted')]);
    }
}
