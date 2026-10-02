<?php

namespace App\Models;

use App\Casts\DateOnly;
use App\Enums\Section;
use App\Enums\SubscriptionStatus;
use App\Models\Concerns\BelongsToUser;
use App\Support\WhatsApp\WhatsAppLinkBuilder;
use Carbon\CarbonImmutable;
use Carbon\CarbonInterface;
use Database\Factories\StudentFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Attributes\Scope;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Casts\Attribute;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Database\Eloquent\SoftDeletes;

/**
 * Subscription date columns (first/last/next) are deliberately NOT fillable:
 * they are maintained exclusively by App\Services\SubscriptionService.
 *
 * @property int $id
 * @property int $user_id
 * @property int $number
 * @property string $name
 * @property string $phone
 * @property string $code
 * @property ?Section $section NULL = not chosen yet (legacy free-text rows)
 * @property ?string $notes
 * @property CarbonImmutable $first_subscription_date
 * @property CarbonImmutable $last_subscription_date
 * @property CarbonImmutable $next_renewal_date
 */
#[Fillable(['name', 'phone', 'code', 'section', 'notes'])]
class Student extends Model
{
    /** @use HasFactory<StudentFactory> */
    use BelongsToUser, HasFactory, SoftDeletes;

    protected function casts(): array
    {
        return [
            'number' => 'integer',
            'section' => Section::class,
            'first_subscription_date' => DateOnly::class,
            'last_subscription_date' => DateOnly::class,
            'next_renewal_date' => DateOnly::class,
        ];
    }

    public function subscriptions(): HasMany
    {
        return $this->hasMany(Subscription::class)->latest('start_date');
    }

    public function status(?CarbonInterface $today = null): SubscriptionStatus
    {
        return SubscriptionStatus::resolve($this->next_renewal_date, $today ?? today());
    }

    /**
     * Positive = days left until renewal, 0 = due today, negative = days overdue.
     */
    public function daysUntilRenewal(?CarbonInterface $today = null): int
    {
        return (int) ($today ?? today())->copy()->startOfDay()->diffInDays($this->next_renewal_date, false);
    }

    public function whatsappUrl(?string $template = null): string
    {
        return app(WhatsAppLinkBuilder::class)->forStudent($this, $template);
    }

    /**
     * Stored as entered, minus whitespace; the international form is built at display time.
     */
    protected function phone(): Attribute
    {
        return Attribute::make(
            set: fn (?string $value) => $value === null ? null : preg_replace('/\s+/u', '', $value),
        );
    }

    #[Scope]
    protected function withStatus(Builder $query, SubscriptionStatus $status, ?CarbonInterface $today = null): void
    {
        $status->constrain($query, $today ?? today());
    }

    /**
     * Expired, due today or due tomorrow — i.e. next_renewal_date <= tomorrow.
     */
    #[Scope]
    protected function needsAttention(Builder $query, ?CarbonInterface $today = null): void
    {
        $query->where('next_renewal_date', '<=', ($today ?? today())->copy()->addDay()->toDateString());
    }

    #[Scope]
    protected function search(Builder $query, ?string $term): void
    {
        $term = trim((string) $term);

        if ($term === '') {
            return;
        }

        $like = '%'.addcslashes($term, '%_\\').'%';
        $phoneLike = '%'.addcslashes(preg_replace('/\s+/u', '', $term), '%_\\').'%';

        $query->where(fn (Builder $q) => $q
            ->where('code', 'like', $like)
            ->orWhere('name', 'like', $like)
            ->orWhere('phone', 'like', $phoneLike));
    }

    /**
     * Per-status counts in a single aggregate query.
     *
     * @return array<string, int> keyed by SubscriptionStatus value, plus 'all'
     */
    public static function statusCounts(Builder $query, ?CarbonInterface $today = null): array
    {
        $today = ($today ?? today())->copy()->startOfDay();
        $todayStr = $today->toDateString();
        $tomorrowStr = $today->copy()->addDay()->toDateString();

        $row = (clone $query)
            ->toBase()
            ->selectRaw('count(*) as total')
            ->selectRaw('coalesce(sum(case when next_renewal_date > ? then 1 else 0 end), 0) as active', [$tomorrowStr])
            ->selectRaw('coalesce(sum(case when next_renewal_date = ? then 1 else 0 end), 0) as due_tomorrow', [$tomorrowStr])
            ->selectRaw('coalesce(sum(case when next_renewal_date = ? then 1 else 0 end), 0) as due_today', [$todayStr])
            ->selectRaw('coalesce(sum(case when next_renewal_date < ? then 1 else 0 end), 0) as expired', [$todayStr])
            ->first();

        return [
            'all' => (int) $row->total,
            SubscriptionStatus::Active->value => (int) $row->active,
            SubscriptionStatus::DueTomorrow->value => (int) $row->due_tomorrow,
            SubscriptionStatus::DueToday->value => (int) $row->due_today,
            SubscriptionStatus::Expired->value => (int) $row->expired,
        ];
    }

    /**
     * Student count per section value ('' = section not chosen yet), every Section case included.
     *
     * @return array<string, int>
     */
    public static function sectionCounts(Builder $query): array
    {
        $rows = (clone $query)
            ->toBase()
            ->selectRaw('section, count(*) as total')
            ->groupBy('section')
            ->pluck('total', 'section');

        $counts = [];

        foreach (Section::cases() as $section) {
            $counts[$section->value] = (int) ($rows[$section->value] ?? 0);
        }

        $counts[''] = (int) ($rows[''] ?? 0);

        return $counts;
    }
}
