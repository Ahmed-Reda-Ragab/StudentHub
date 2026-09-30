@props(['icon' => 'users', 'title', 'body' => null])

<div {{ $attributes->merge(['class' => 'flex flex-col items-center px-6 py-14 text-center']) }}>
    <div class="mb-4 flex size-14 items-center justify-center rounded-full bg-indigo-50 text-indigo-600">
        <x-icon :name="$icon" class="size-7" />
    </div>
    <h3 class="text-base font-bold text-slate-900">{{ $title }}</h3>
    @if ($body)
        <p class="mt-1 max-w-sm text-sm text-slate-500">{{ $body }}</p>
    @endif
    @if ($slot->isNotEmpty())
        <div class="mt-6">{{ $slot }}</div>
    @endif
</div>
