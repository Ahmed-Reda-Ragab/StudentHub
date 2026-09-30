@props([
    'name',
    'label',
    'type' => 'text',
    'value' => null,
    'hint' => null,
    'bag' => 'default',
])

@php
    $id = $attributes->get('id', 'field-'.$name);
    $error = $errors->getBag($bag)->first($name);
@endphp

<div>
    <label for="{{ $id }}" class="mb-1.5 block text-sm font-medium text-slate-700">
        {{ $label }}
        @if ($attributes->has('required'))<span class="text-red-500" aria-hidden="true">*</span>@endif
    </label>

    <input
        id="{{ $id }}"
        name="{{ $name }}"
        type="{{ $type }}"
        value="{{ old($name, $value) }}"
        @if ($error) aria-invalid="true" aria-describedby="{{ $id }}-error" @endif
        {{ $attributes->except('id')->merge(['class' => 'form-input']) }}
    >

    {{ $slot }}

    @if ($error)
        <p id="{{ $id }}-error" class="mt-1.5 flex items-center gap-1 text-sm text-red-600">
            <x-icon name="exclamation-circle" class="size-4" />{{ $error }}
        </p>
    @elseif ($hint)
        <p class="mt-1.5 text-sm text-slate-500">{{ $hint }}</p>
    @endif
</div>
