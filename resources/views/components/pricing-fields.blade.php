@props(['bag' => 'default', 'idPrefix' => 'field'])

{{-- Expects an enclosing Alpine scope exposing `price` and `commission`. --}}
@php
    $currency = __('subscriptions.pricing.currency');
@endphp

<div {{ $attributes->merge(['class' => 'grid grid-cols-2 gap-4']) }}>
    <x-input
        name="price"
        type="number"
        step="0.01"
        min="0"
        inputmode="decimal"
        dir="ltr"
        :bag="$bag"
        :id="$idPrefix.'-price'"
        :label="__('subscriptions.pricing.price').' ('.$currency.')'"
        x-model="price"
        required
    />
    <x-input
        name="commission"
        type="number"
        step="0.01"
        min="0"
        inputmode="decimal"
        dir="ltr"
        :bag="$bag"
        :id="$idPrefix.'-commission'"
        :label="__('subscriptions.pricing.commission').' ('.$currency.')'"
        x-model="commission"
        x-bind:max="price"
        required
    />
</div>
