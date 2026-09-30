@props([
    'type' => 'submit',
    'variant' => 'primary',
    'loadingText' => null,
    'icon' => null,
    'href' => null,
])

@php
    $variants = [
        'primary' => 'bg-indigo-600 text-white shadow-sm hover:bg-indigo-500 focus-visible:outline-indigo-600',
        'secondary' => 'bg-white text-slate-700 shadow-xs ring-1 ring-slate-300 ring-inset hover:bg-slate-50',
        'danger' => 'bg-red-600 text-white shadow-sm hover:bg-red-500 focus-visible:outline-red-600',
        'whatsapp' => 'bg-emerald-600 text-white shadow-sm hover:bg-emerald-500 focus-visible:outline-emerald-600',
        'ghost' => 'text-slate-600 hover:bg-slate-100 hover:text-slate-900',
    ];

    $classes = 'inline-flex min-h-11 items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm font-semibold transition '
        .'disabled:cursor-not-allowed disabled:opacity-70 '
        .($variants[$variant] ?? $variants['primary']);

    $isSubmit = $type === 'submit' && ! $href;
    $loadingText ??= __('app.actions.saving');
@endphp

@if ($href)
    <a href="{{ $href }}" {{ $attributes->merge(['class' => $classes]) }}>
        @if ($icon)<x-icon :name="$icon" />@endif
        <span>{{ $slot }}</span>
    </a>
@elseif ($isSubmit)
    {{-- Relies on the enclosing <x-form> (Alpine `loading`). Label and loader share one grid cell so the width never jumps. --}}
    <button
        type="submit"
        :disabled="loading"
        :aria-busy="loading.toString()"
        {{ $attributes->merge(['class' => $classes]) }}
    >
        <span class="grid">
            <span class="col-start-1 row-start-1 inline-flex items-center justify-center gap-2" :class="loading && 'invisible'">
                @if ($icon)<x-icon :name="$icon" />@endif
                <span>{{ $slot }}</span>
            </span>
            <span class="invisible col-start-1 row-start-1 inline-flex items-center justify-center gap-2" :class="loading && '!visible'" aria-live="polite">
                <x-icon name="spinner" />
                <span x-show="loading" x-cloak>{{ $loadingText }}</span>
            </span>
        </span>
    </button>
@else
    <button type="{{ $type }}" {{ $attributes->merge(['class' => $classes]) }}>
        @if ($icon)<x-icon :name="$icon" />@endif
        <span>{{ $slot }}</span>
    </button>
@endif
