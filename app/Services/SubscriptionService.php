<?php

namespace App\Services;

use App\Enums\SubscriptionType;
use App\Models\Student;
use App\Models\Subscription;
use App\Models\User;
use App\Support\SubscriptionPeriod;
use Carbon\CarbonImmutable;
use Carbon\CarbonInterface;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Support\Arr;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\ValidationException;

/**
 * The ONLY writer of students.first_subscription_date / last_subscription_date /
 * next_renewal_date and of the subscriptions ledger.
 */
class SubscriptionService
{
    public function __construct(private readonly SubscriptionPeriod $period) {}

    /**
     * @param  array{name: string, phone: string, code: string, section: string, notes?: ?string, subscribed_on: string|CarbonInterface, price?: numeric|null, commission?: numeric|null}  $data
     *
     * @throws ValidationException
     */
    public function addStudent(User $user, array $data): Student
    {
        $startDate = CarbonImmutable::parse($data['subscribed_on'])->startOfDay();
        $endsOn = $this->period->endsOn($startDate);
        $nextRenewal = $this->period->nextRenewal($startDate);
        $pricing = $this->pricing($data['price'] ?? null, $data['commission'] ?? null);

        try {
            return DB::transaction(function () use ($user, $data, $startDate, $endsOn, $nextRenewal, $pricing) {
                // Lock the owner row so concurrent inserts for the same user get sequential numbers.
                User::query()->whereKey($user->getKey())->lockForUpdate()->first();

                $student = new Student(Arr::only($data, ['name', 'phone', 'code', 'section', 'notes']));
                $student->forceFill([
                    'user_id' => $user->getKey(),
                    'number' => $this->nextNumberFor($user),
                    'first_subscription_date' => $startDate,
                    'last_subscription_date' => $startDate,
                    'next_renewal_date' => $nextRenewal,
                ])->save();

                $student->subscriptions()->create([
                    'user_id' => $user->getKey(),
                    'type' => SubscriptionType::Initial,
                    'start_date' => $startDate,
                    'ends_on' => $endsOn,
                    ...$pricing,
                ]);

                return $student;
            });
        } catch (UniqueConstraintViolationException) {
            throw ValidationException::withMessages([
                'code' => __('students.messages.code_taken'),
            ]);
        }
    }

    /**
     * @throws ValidationException
     */
    public function renew(
        Student $student,
        CarbonInterface $date,
        int|float|string|null $price = null,
        int|float|string|null $commission = null,
        ?string $note = null,
    ): Subscription {
        $startDate = CarbonImmutable::parse($date->toDateString());
        $endsOn = $this->period->endsOn($startDate);
        $nextRenewal = $this->period->nextRenewal($startDate);
        $pricing = $this->pricing($price, $commission);

        try {
            $subscription = DB::transaction(function () use ($student, $startDate, $endsOn, $nextRenewal, $pricing, $note) {
                /** @var Student $locked */
                $locked = Student::query()
                    ->withoutGlobalScopes()
                    ->whereKey($student->getKey())
                    ->lockForUpdate()
                    ->firstOrFail();

                $this->ensureRenewalDateIsValid($locked, $startDate);

                $subscription = $locked->subscriptions()->create([
                    'user_id' => $locked->user_id,
                    'type' => SubscriptionType::Renewal,
                    'start_date' => $startDate,
                    'ends_on' => $endsOn,
                    ...$pricing,
                    'note' => $note,
                ]);

                $locked->forceFill([
                    'last_subscription_date' => $startDate,
                    'next_renewal_date' => $nextRenewal,
                ])->save();

                return $subscription;
            });
        } catch (UniqueConstraintViolationException) {
            throw ValidationException::withMessages([
                'renewed_on' => __('subscriptions.messages.duplicate_renewal'),
            ]);
        }

        $student->refresh();

        return $subscription;
    }

    /**
     * The new date must stay strictly between the neighbouring entries, so the
     * ledger order (and the initial subscription being first) never changes.
     *
     * @throws ValidationException
     */
    public function update(
        Subscription $subscription,
        CarbonInterface $date,
        int|float|string|null $price,
        int|float|string|null $commission,
        ?string $note = null,
    ): Subscription {
        $startDate = CarbonImmutable::parse($date->toDateString());
        $pricing = $this->pricing($price, $commission);

        try {
            DB::transaction(function () use ($subscription, $startDate, $pricing, $note) {
                $student = $this->lockStudent($subscription->student_id);

                $this->ensureDateFitsBetweenNeighbours($subscription, $startDate);

                $subscription->update([
                    'start_date' => $startDate,
                    'ends_on' => $this->period->endsOn($startDate),
                    ...$pricing,
                    'note' => $note,
                ]);

                $this->syncStudentDates($student);
            });
        } catch (UniqueConstraintViolationException) {
            throw ValidationException::withMessages([
                'start_date' => __('subscriptions.messages.duplicate_renewal'),
            ]);
        }

        return $subscription;
    }

    /**
     * Only renewals can be deleted — the initial subscription goes with the student.
     *
     * @throws ValidationException
     */
    public function delete(Subscription $subscription): void
    {
        if ($subscription->type === SubscriptionType::Initial) {
            throw ValidationException::withMessages([
                'subscription' => __('subscriptions.messages.cannot_delete_initial'),
            ]);
        }

        DB::transaction(function () use ($subscription) {
            $student = $this->lockStudent($subscription->student_id);

            $subscription->delete();

            $this->syncStudentDates($student);
        });
    }

    private function lockStudent(int $studentId): Student
    {
        return Student::query()
            ->withoutGlobalScopes()
            ->whereKey($studentId)
            ->lockForUpdate()
            ->firstOrFail();
    }

    /**
     * Rebuilds first/last/next dates from the ledger after an edit or deletion.
     */
    private function syncStudentDates(Student $student): void
    {
        $dates = Subscription::query()
            ->withoutGlobalScopes()
            ->where('student_id', $student->getKey())
            ->toBase()
            ->selectRaw('min(start_date) as first, max(start_date) as last')
            ->first();

        $last = CarbonImmutable::parse($dates->last);

        $student->forceFill([
            'first_subscription_date' => CarbonImmutable::parse($dates->first),
            'last_subscription_date' => $last,
            'next_renewal_date' => $this->period->nextRenewal($last),
        ])->save();
    }

    /**
     * @throws ValidationException
     */
    private function ensureDateFitsBetweenNeighbours(Subscription $subscription, CarbonImmutable $date): void
    {
        $siblings = Subscription::query()
            ->withoutGlobalScopes()
            ->where('student_id', $subscription->student_id)
            ->whereKeyNot($subscription->getKey());

        // Plain "Y-m-d" — a Carbon binding would compare as "Y-m-d H:i:s" on SQLite.
        $original = $subscription->getOriginal('start_date')->toDateString();

        $previous = (clone $siblings)->where('start_date', '<', $original)->max('start_date');
        $next = (clone $siblings)->where('start_date', '>', $original)->min('start_date');

        if ($previous && $date->lte(CarbonImmutable::parse($previous))) {
            throw ValidationException::withMessages([
                'start_date' => __('subscriptions.messages.date_after', [
                    'date' => CarbonImmutable::parse($previous)->format('d/m/Y'),
                ]),
            ]);
        }

        if ($next && $date->gte(CarbonImmutable::parse($next))) {
            throw ValidationException::withMessages([
                'start_date' => __('subscriptions.messages.date_before', [
                    'date' => CarbonImmutable::parse($next)->format('d/m/Y'),
                ]),
            ]);
        }
    }

    /**
     * Falls back to the configured defaults; commission (profit) can never exceed the price.
     *
     * @return array{price: float, commission: float}
     *
     * @throws ValidationException
     */
    private function pricing(int|float|string|null $price, int|float|string|null $commission): array
    {
        $price = (float) ($price ?? config('subscriptions.pricing.price'));
        $commission = (float) ($commission ?? config('subscriptions.pricing.commission'));

        if ($price < 0 || $commission < 0 || $commission > $price) {
            throw ValidationException::withMessages([
                'commission' => __('validation.custom.commission.lte'),
            ]);
        }

        return ['price' => $price, 'commission' => $commission];
    }

    private function nextNumberFor(User $user): int
    {
        // Includes soft-deleted students: numbers are never reused.
        return (int) Student::query()
            ->withoutGlobalScopes()
            ->where('user_id', $user->getKey())
            ->max('number') + 1;
    }

    /**
     * @throws ValidationException
     */
    private function ensureRenewalDateIsValid(Student $student, CarbonImmutable $date): void
    {
        $last = $student->last_subscription_date;

        if ($date->isSameDay($last)) {
            throw ValidationException::withMessages([
                'renewed_on' => __('subscriptions.messages.duplicate_renewal'),
            ]);
        }

        if ($date->lt($last)) {
            throw ValidationException::withMessages([
                'renewed_on' => __('subscriptions.messages.renewal_before_last', [
                    'date' => $last->format('d/m/Y'),
                ]),
            ]);
        }
    }
}
