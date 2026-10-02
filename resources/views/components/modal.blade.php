@props(['name', 'title', 'show' => false])

{{--
    Open:  $dispatch('open-modal', 'name')     Close: Esc, backdrop, or $dispatch('close-modal', 'name')
    x-trap traps focus while open and restores it to the trigger on close.
--}}
<div
    x-data="{ open: @js($show) }"
    x-on:open-modal.window="$event.detail === @js($name) && (open = true)"
    x-on:close-modal.window="$event.detail === @js($name) && (open = false)"
    x-on:keydown.escape.window="open = false"
    x-show="open"
    x-cloak
    class="fixed inset-0 z-50 flex items-end justify-center p-4 sm:items-center"
    role="dialog"
    aria-modal="true"
    aria-labelledby="modal-{{ $name }}-title"
>
    <div x-show="open" x-transition.opacity class="fixed inset-0 bg-slate-900/40" @click="open = false"></div>

    <div
        x-show="open"
        x-transition
        x-trap.inert.noscroll="open"
        class="card relative max-h-[calc(100dvh-2rem)] w-full max-w-md overflow-y-auto overscroll-contain p-6 shadow-xl"
    >
        <div class="mb-4 flex items-start justify-between gap-4">
            <h2 id="modal-{{ $name }}-title" class="text-lg font-bold text-slate-900">{{ $title }}</h2>
            <button type="button" @click="open = false" class="-m-2 inline-flex size-11 items-center justify-center rounded-lg text-slate-400 hover:text-slate-600" aria-label="{{ __('app.actions.close') }}">
                <x-icon name="x-mark" />
            </button>
        </div>

        {{ $slot }}
    </div>
</div>
