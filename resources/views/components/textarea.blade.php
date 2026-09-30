@props(['name', 'label', 'value' => null])

@php
    $id = 'field-'.$name;
    $error = $errors->first($name);
@endphp

<div>
    <label for="{{ $id }}" class="mb-1.5 block text-sm font-medium text-slate-700">{{ $label }}</label>

    <textarea
        id="{{ $id }}"
        name="{{ $name }}"
        rows="3"
        @if ($error) aria-invalid="true" aria-describedby="{{ $id }}-error" @endif
        {{ $attributes->merge(['class' => 'form-input']) }}
    >{{ old($name, $value) }}</textarea>

    @if ($error)
        <p id="{{ $id }}-error" class="mt-1.5 flex items-center gap-1 text-sm text-red-600">
            <x-icon name="exclamation-circle" class="size-4" />{{ $error }}
        </p>
    @endif
</div>
