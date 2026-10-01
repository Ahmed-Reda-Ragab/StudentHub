<?php

namespace App\Models;

use App\Casts\DateOnly;
use App\Enums\SubscriptionType;
use App\Models\Concerns\BelongsToUser;
use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * Ledger entry. Edits and deletions go through App\Services\SubscriptionService,
 * which keeps the student's denormalized dates in sync with the ledger.
 *
 * @property int $id
 * @property int $student_id
 * @property int $user_id
 * @property SubscriptionType $type
 * @property CarbonImmutable $start_date
 * @property CarbonImmutable $ends_on
 * @property string $price what the student paid
 * @property string $commission the user's profit out of the price
 * @property ?string $note
 */
#[Fillable(['user_id', 'type', 'start_date', 'ends_on', 'price', 'commission', 'note'])]
class Subscription extends Model
{
    use BelongsToUser;

    protected function casts(): array
    {
        return [
            'type' => SubscriptionType::class,
            'start_date' => DateOnly::class,
            'ends_on' => DateOnly::class,
            'price' => 'decimal:2',
            'commission' => 'decimal:2',
        ];
    }

    public function student(): BelongsTo
    {
        return $this->belongsTo(Student::class)->withTrashed();
    }
}
