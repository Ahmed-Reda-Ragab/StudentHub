@props(['student', 'label' => null, 'variant' => 'primary'])

<x-button
    type="button"
    :variant="$variant"
    icon="arrow-path"
    x-data
    x-on:click="$dispatch('open-renewal', {{ \Illuminate\Support\Js::from([
        'action' => route('students.renewals.store', $student),
        'name' => $student->name,
        'last' => $student->last_subscription_date->format('d/m/Y'),
    ]) }})"
    {{ $attributes }}
>
    {{ $label ?? __('subscriptions.renew.button') }}
</x-button>
