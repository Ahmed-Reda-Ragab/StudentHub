{{--
    One edit modal per page, opened via the `edit-subscription` window event with
    {action, date, price, commission, note}. On a failed submit (error bag "subscription")
    it re-opens itself with the posted values.
--}}
@php
    $errorBag = $errors->getBag('subscription');
@endphp

<div
    x-data="{
        open: @js($errorBag->any()),
        action: @js(old('subscription_action', '')),
        date: @js(old('start_date', '')),
        price: @js((string) old('price', '')),
        commission: @js((string) old('commission', '')),
        note: @js((string) old('note', '')),
        show(detail) {
            Object.assign(this, detail, { open: true });
            this.$nextTick(() => this.$refs.date.focus());
        },
    }"
    x-init="open && $nextTick(() => $refs.date.focus())"
    x-on:edit-subscription.window="show($event.detail)"
    x-on:keydown.escape.window="open = false"
    x-show="open"
    x-cloak
    class="fixed inset-0 z-50 flex items-end justify-center p-4 sm:items-center"
    role="dialog"
    aria-modal="true"
    aria-labelledby="subscription-modal-title"
>
    <div x-show="open" x-transition.opacity class="fixed inset-0 bg-slate-900/40" @click="open = false"></div>

    <div x-show="open" x-transition x-trap.inert.noscroll="open" class="card relative w-full max-w-md p-6 shadow-xl">
        <div class="mb-4 flex items-start justify-between gap-4">
            <h2 id="subscription-modal-title" class="text-lg font-bold text-slate-900">{{ __('subscriptions.edit.title') }}</h2>
            <button type="button" @click="open = false" class="-m-2 inline-flex size-11 items-center justify-center rounded-lg text-slate-400 hover:text-slate-600" aria-label="{{ __('app.actions.close') }}">
                <x-icon name="x-mark" />
            </button>
        </div>

        <x-form action="" x-bind:action="action" method="PUT" class="space-y-4">
            <input type="hidden" name="subscription_action" x-bind:value="action">

            <x-input
                name="start_date"
                type="date"
                bag="subscription"
                :label="__('subscriptions.edit.date')"
                x-model="date"
                x-ref="date"
                required
                id="subscription-date"
            >
                <x-period-preview />
            </x-input>

            <x-pricing-fields bag="subscription" id-prefix="subscription" />

            <x-input
                name="note"
                bag="subscription"
                :label="__('subscriptions.edit.note')"
                x-model="note"
                maxlength="255"
                id="subscription-note"
            />

            <div class="flex flex-col-reverse gap-2 pt-2 sm:flex-row sm:justify-end">
                <x-button type="button" variant="secondary" x-on:click="open = false">{{ __('app.actions.cancel') }}</x-button>
                <x-button icon="pencil-square" :loading-text="__('app.actions.saving')">{{ __('app.actions.save') }}</x-button>
            </div>
        </x-form>
    </div>
</div>
