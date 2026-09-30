{{--
    One renewal modal per page, opened by <x-renew-button> via the `open-renewal` window event.
    On a failed submit (error bag "renewal") it re-opens itself with the posted values.
--}}
@php
    $errorBag = $errors->getBag('renewal');
    $today = today()->toDateString();
    $defaultPrice = (string) config('subscriptions.pricing.price');
    $defaultCommission = (string) config('subscriptions.pricing.commission');
@endphp

<div
    x-data="{
        open: @js($errorBag->any()),
        action: @js(old('renewal_action', '')),
        name: @js(old('renewal_name', '')),
        last: @js(old('renewal_last', '')),
        date: @js(old('renewed_on', $today)),
        price: @js((string) old('price', $defaultPrice)),
        commission: @js((string) old('commission', $defaultCommission)),
        show(detail) {
            Object.assign(this, detail, {
                date: @js($today),
                price: @js($defaultPrice),
                commission: @js($defaultCommission),
                open: true,
            });
            this.$nextTick(() => this.$refs.date.focus());
        },
    }"
    x-init="open && $nextTick(() => $refs.date.focus())"
    x-on:open-renewal.window="show($event.detail)"
    x-on:keydown.escape.window="open = false"
    x-show="open"
    x-cloak
    class="fixed inset-0 z-50 flex items-end justify-center p-4 sm:items-center"
    role="dialog"
    aria-modal="true"
    aria-labelledby="renewal-modal-title"
>
    <div x-show="open" x-transition.opacity class="fixed inset-0 bg-slate-900/40" @click="open = false"></div>

    <div x-show="open" x-transition x-trap.inert.noscroll="open" class="card relative w-full max-w-md p-6 shadow-xl">
        <div class="mb-4 flex items-start justify-between gap-4">
            <div>
                <h2 id="renewal-modal-title" class="text-lg font-bold text-slate-900">{{ __('subscriptions.renew.title') }}</h2>
                <p class="mt-1 text-sm text-slate-600" x-text="@js(__('subscriptions.renew.for', ['name' => '__NAME__'])).replace('__NAME__', name)"></p>
            </div>
            <button type="button" @click="open = false" class="-m-2 inline-flex size-11 items-center justify-center rounded-lg text-slate-400 hover:text-slate-600" aria-label="{{ __('app.actions.close') }}">
                <x-icon name="x-mark" />
            </button>
        </div>

        <x-form action="" x-bind:action="action" class="space-y-4">
            <input type="hidden" name="renewal_action" x-bind:value="action">
            <input type="hidden" name="renewal_name" x-bind:value="name">
            <input type="hidden" name="renewal_last" x-bind:value="last">

            <x-input
                name="renewed_on"
                type="date"
                bag="renewal"
                :label="__('subscriptions.renew.date')"
                x-model="date"
                x-ref="date"
                required
                id="renewal-date"
            >
                <p class="mt-2 flex items-center gap-1.5 text-sm text-indigo-700" x-show="$nextRenewal(date)">
                    <x-icon name="calendar" class="size-4" />
                    {{ __('students.preview') }}
                    <strong class="ltr-nums" x-text="$nextRenewal(date)"></strong>
                </p>
                <p class="mt-1 text-xs text-slate-500 ltr-nums" x-show="last" x-text="@js(__('subscriptions.renew.last', ['date' => '__D__'])).replace('__D__', last)"></p>
            </x-input>

            <x-pricing-fields bag="renewal" id-prefix="renewal" />

            <div class="flex flex-col-reverse gap-2 pt-2 sm:flex-row sm:justify-end">
                <x-button type="button" variant="secondary" x-on:click="open = false">{{ __('app.actions.cancel') }}</x-button>
                <x-button icon="arrow-path" :loading-text="__('subscriptions.renew.loading')">{{ __('subscriptions.renew.submit') }}</x-button>
            </div>
        </x-form>
    </div>
</div>
