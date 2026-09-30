@props(['action', 'method' => 'POST'])

@php
    $method = strtoupper($method);
@endphp

{{--
    Every mutating form goes through here:
    - Alpine `submitGuard` → loading state for <x-button>, blocks re-submits (incl. Enter key)
    - one-off `_submission_token` → server-side idempotency (PreventDuplicateSubmissions)
--}}
<form
    method="{{ $method === 'GET' ? 'GET' : 'POST' }}"
    action="{{ $action }}"
    x-data="submitGuard"
    @submit="guard($event)"
    :aria-busy="loading.toString()"
    {{ $attributes }}
>
    @unless ($method === 'GET')
        @csrf
        <input type="hidden" name="{{ \App\Http\Middleware\PreventDuplicateSubmissions::FIELD }}" value="{{ (string) \Illuminate\Support\Str::uuid() }}">
    @endunless

    @if (! in_array($method, ['GET', 'POST'], true))
        @method($method)
    @endif

    {{ $slot }}
</form>
