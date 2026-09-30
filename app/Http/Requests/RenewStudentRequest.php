<?php

namespace App\Http\Requests;

use Carbon\CarbonImmutable;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * Format-only validation here; the business rule (date must be after the last
 * subscription date) is enforced atomically inside SubscriptionService::renew().
 */
class RenewStudentRequest extends FormRequest
{
    /**
     * Keep the modal open on the page when validation fails.
     */
    protected $errorBag = 'renewal';

    public function authorize(): bool
    {
        return $this->user()?->can('renew', $this->route('student')) ?? false;
    }

    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'renewed_on' => ['required', 'date_format:Y-m-d'],
            'note' => ['nullable', 'string', 'max:255'],
        ];
    }

    public function renewalDate(): CarbonImmutable
    {
        return CarbonImmutable::createFromFormat('!Y-m-d', $this->validated('renewed_on'));
    }
}
