@props(['label', 'value', 'icon', 'tone' => 'indigo', 'href' => null])

@php
    $tones = [
        'indigo' => 'bg-indigo-50 text-indigo-600',
        'emerald' => 'bg-emerald-50 text-emerald-600',
        'amber' => 'bg-amber-50 text-amber-600',
        'red' => 'bg-red-50 text-red-600',
    ];
    $tag = $href ? 'a' : 'div';
@endphp

<{{ $tag }} @if ($href) href="{{ $href }}" @endif class="card flex items-center gap-4 p-5 transition {{ $href ? 'hover:ring-indigo-300' : '' }}">
    <div class="flex size-12 shrink-0 items-center justify-center rounded-xl {{ $tones[$tone] ?? $tones['indigo'] }}">
        <x-icon :name="$icon" class="size-6" />
    </div>
    <div>
        <p class="text-sm text-slate-500">{{ $label }}</p>
        <p class="text-2xl font-bold text-slate-900 ltr-nums">{{ $value }}</p>
    </div>
</{{ $tag }}>
