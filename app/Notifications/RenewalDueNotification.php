<?php

namespace App\Notifications;

use App\Models\Student;
use Carbon\CarbonInterface;
use Illuminate\Notifications\Notification;
use Illuminate\Support\Collection;

/**
 * Daily digest: "N students renew tomorrow". Stored in the database channel only
 * and sent synchronously (intentionally not ShouldQueue).
 */
class RenewalDueNotification extends Notification
{
    private const SAMPLE_SIZE = 10;

    /**
     * @param  Collection<int, Student>  $students
     */
    public function __construct(
        private readonly Collection $students,
        private readonly CarbonInterface $dueDate,
    ) {}

    /**
     * @return list<string>
     */
    public function via(object $notifiable): array
    {
        return ['database'];
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(object $notifiable): array
    {
        return [
            'count' => $this->students->count(),
            'due_date' => $this->dueDate->toDateString(),
            'message' => trans_choice('notifications.digest', $this->students->count(), [
                'count' => $this->students->count(),
            ]),
            'students' => $this->students
                ->take(self::SAMPLE_SIZE)
                ->map(fn (Student $student) => [
                    'id' => $student->id,
                    'name' => $student->name,
                    'code' => $student->code,
                ])
                ->values()
                ->all(),
        ];
    }
}
