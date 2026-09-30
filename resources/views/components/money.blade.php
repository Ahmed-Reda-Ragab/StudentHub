@props(['value'])

{{-- 200.00 → "200 ج.م", 150.50 → "150.5 ج.م" (Latin digits, easy to copy).
     Plain number_format() on purpose: Number::format() needs the intl extension, which production lacks. --}}
<span {{ $attributes->merge(['class' => 'whitespace-nowrap']) }}><span class="ltr-nums">{{ rtrim(rtrim(number_format((float) $value, 2, '.', ','), '0'), '.') }}</span> {{ __('subscriptions.pricing.currency') }}</span>
