<?php

namespace App\Models;

use App\Casts\DateOnly;
use App\Enums\SubscriptionType;
use App\Models\Concerns\BelongsToUser;
use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use LogicException;

/**
 * Append-only ledger entry. Records are never updated or deleted by the
 * application (DB-level cascade on student/user removal is the only exception).
 *
 * @property int $id
 * @property int $student_id
 * @property int $user_id
 * @property SubscriptionType $type
 * @property CarbonImmutable $start_date
 * @property CarbonImmutable $ends_on
 * @property ?string $amount
 * @property ?string $note
 */
#[Fillable(['user_id', 'type', 'start_date', 'ends_on', 'amount', 'note'])]
class Subscription extends Model
{
    use BelongsToUser;

    protected static function booted(): void
    {
        static::updating(fn () => throw new LogicException('Subscriptions are append-only and cannot be updated.'));
        static::deleting(fn () => throw new LogicException('Subscriptions are append-only and cannot be deleted.'));
    }

    protected function casts(): array
    {
        return [
            'type' => SubscriptionType::class,
            'start_date' => DateOnly::class,
            'ends_on' => DateOnly::class,
            'amount' => 'decimal:2',
        ];
    }

    public function student(): BelongsTo
    {
        return $this->belongsTo(Student::class)->withTrashed();
    }
}
