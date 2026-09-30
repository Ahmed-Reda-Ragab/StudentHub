@props(['title' => null])

<!DOCTYPE html>
<html lang="{{ str_replace('_', '-', app()->getLocale()) }}" dir="rtl">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{ $title ? $title.' · ' : '' }}{{ __('app.name') }}</title>
    {{ Vite::fonts() }}
    @vite(['resources/css/app.css', 'resources/js/app.js'])
</head>
<body class="flex min-h-screen flex-col items-center justify-center px-4 py-10">
    <x-toast />

    <a href="{{ route('login') }}" class="mb-8 flex items-center gap-2 text-lg font-bold text-slate-900">
        <span class="flex size-10 items-center justify-center rounded-xl bg-indigo-600 text-white">
            <x-icon name="academic-cap" class="size-6" />
        </span>
        {{ __('app.name') }}
    </a>

    <main id="main" class="card w-full max-w-md p-6 sm:p-8">
        {{ $slot }}
    </main>
</body>
</html>
