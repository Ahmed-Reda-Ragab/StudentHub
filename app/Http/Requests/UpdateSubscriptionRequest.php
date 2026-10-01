<?php

namespace App\Http\Requests;

use App\Http\Requests\Concerns\ValidatesPricing;
use Carbon\CarbonImmutable;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * Format-only validation here; ordering against the other ledger entries is
 * enforced atomically inside SubscriptionService::update().
 */
class UpdateSubscriptionRequest extends FormRequest
{
    use ValidatesPricing;

    /**
     * Keep the edit modal open on the page when validation fails.
     */
    protected $errorBag = 'subscription';

    public function authorize(): bool
    {
        return $this->user()?->can('update', $this->route('subscription')) ?? false;
    }

    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'start_date' => ['required', 'date_format:Y-m-d'],
            'note' => ['nullable', 'string', 'max:255'],
            ...$this->pricingRules(),
        ];
    }

    public function startDate(): CarbonImmutable
    {
        return CarbonImmutable::createFromFormat('!Y-m-d', $this->validated('start_date'));
    }
}
