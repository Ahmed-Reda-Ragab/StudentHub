@props(['value'])

{{-- 200.00 → "200 ج.م", 150.50 → "150.5 ج.م" (Latin digits, easy to copy) --}}
<span {{ $attributes->merge(['class' => 'whitespace-nowrap']) }}><span class="ltr-nums">{{ \Illuminate\Support\Number::format((float) $value, maxPrecision: 2, locale: 'en') }}</span> {{ __('subscriptions.pricing.currency') }}</span>
