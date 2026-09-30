<?php

namespace App\Http\Requests;

use App\Models\Student;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

/**
 * Profile fields only — subscription dates are never editable.
 */
class UpdateStudentRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user()?->can('update', $this->route('student')) ?? false;
    }

    protected function prepareForValidation(): void
    {
        $this->merge([
            'phone' => preg_replace('/\s+/u', '', (string) $this->input('phone')),
            'code' => trim((string) $this->input('code')),
        ]);
    }

    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        /** @var Student $student */
        $student = $this->route('student');

        return [
            ...StoreStudentRequest::profileRules(),
            'code' => [
                'required', 'string', 'max:50',
                Rule::unique('students')->where('user_id', $this->user()->id)->ignore($student->id),
            ],
        ];
    }
}
