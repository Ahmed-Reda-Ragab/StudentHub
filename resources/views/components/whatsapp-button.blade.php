@props(['student', 'compact' => false])

<a
    href="{{ $student->whatsappUrl() }}"
    target="_blank"
    rel="noopener"
    {{ $attributes->merge(['class' => 'inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-emerald-600 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-emerald-500 focus-visible:outline-emerald-600']) }}
    @if ($compact) aria-label="{{ __('whatsapp.button') }} — {{ $student->name }}" @endif
>
    <x-icon name="whatsapp" />
    <span @class(['sr-only sm:not-sr-only' => $compact])>{{ $compact ? __('whatsapp.short') : __('whatsapp.button') }}</span>
</a>
