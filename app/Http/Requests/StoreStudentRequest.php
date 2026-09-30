<?php

namespace App\Http\Requests;

use App\Enums\Section;
use App\Http\Requests\Concerns\ValidatesPricing;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

class StoreStudentRequest extends FormRequest
{
    use ValidatesPricing;

    public function authorize(): bool
    {
        return $this->user() !== null;
    }

    protected function prepareForValidation(): void
    {
        $this->merge([
            'phone' => preg_replace('/\s+/u', '', (string) $this->input('phone')),
            'code' => trim((string) $this->input('code')),
        ]);

        $this->mergeDefaultPricing();
    }

    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            ...self::profileRules(),
            // Codes stay reserved after soft delete (plain unique, trashed rows included).
            'code' => ['required', 'string', 'max:50', Rule::unique('students')->where('user_id', $this->user()->id)],
            'subscribed_on' => ['required', 'date_format:Y-m-d'],
            ...$this->pricingRules(),
        ];
    }

    /**
     * Rules shared with UpdateStudentRequest.
     *
     * @return array<string, array<mixed>>
     */
    public static function profileRules(): array
    {
        return [
            'name' => ['required', 'string', 'max:255'],
            'phone' => ['required', 'string', 'max:20', 'regex:/^\+?[0-9\-()]{7,20}$/'],
            'section' => ['required', Rule::enum(Section::class)],
            'notes' => ['nullable', 'string', 'max:2000'],
        ];
    }
}
