@php
    $toast = session('toast');
    $styles = [
        'success' => ['icon' => 'check-circle', 'class' => 'text-emerald-600'],
        'info' => ['icon' => 'information-circle', 'class' => 'text-indigo-600'],
        'error' => ['icon' => 'exclamation-circle', 'class' => 'text-red-600'],
    ];
    $style = $styles[$toast['type'] ?? 'success'] ?? $styles['success'];
@endphp

@if ($toast)
    <div
        x-data="{ show: true }"
        x-init="setTimeout(() => show = false, 4000)"
        x-show="show"
        x-transition.opacity.duration.300ms
        role="status"
        aria-live="polite"
        class="fixed inset-x-4 top-4 z-[60] mx-auto max-w-md"
    >
        <div class="card flex items-start gap-3 p-4 shadow-lg">
            <x-icon :name="$style['icon']" class="size-6 {{ $style['class'] }}" />
            <p class="flex-1 pt-0.5 text-sm font-medium text-slate-800">{{ $toast['message'] }}</p>
            <button type="button" @click="show = false" class="-m-2 inline-flex size-11 items-center justify-center rounded-lg text-slate-400 hover:text-slate-600" aria-label="{{ __('app.actions.close') }}">
                <x-icon name="x-mark" />
            </button>
        </div>
    </div>
@endif
