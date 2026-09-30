@props(['title' => null])

@php
    $nav = [
        ['route' => 'students.index', 'match' => 'students.*', 'icon' => 'users', 'label' => __('app.nav.students')],
        ['route' => 'notifications.index', 'match' => 'notifications.*', 'icon' => 'bell', 'label' => __('app.nav.notifications')],
        ['route' => 'dashboard', 'match' => 'dashboard', 'icon' => 'chart-bar', 'label' => __('app.nav.dashboard')],
    ];
@endphp

<!DOCTYPE html>
<html lang="{{ str_replace('_', '-', app()->getLocale()) }}" dir="rtl" data-period-days="{{ config('subscriptions.period_days') }}">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="csrf-token" content="{{ csrf_token() }}">
    <title>{{ $title ? $title.' · ' : '' }}{{ __('app.name') }}</title>
    {{ Vite::fonts() }}
    @vite(['resources/css/app.css', 'resources/js/app.js'])
</head>
<body class="min-h-screen">
    <a href="#main" class="sr-only focus:not-sr-only focus:fixed focus:top-2 focus:start-2 focus:z-[70] focus:rounded-lg focus:bg-white focus:px-4 focus:py-2">{{ __('app.skip_to_content') }}</a>

    {{-- Top bar --}}
    <header class="sticky top-0 z-40 border-b border-slate-200 bg-white/90 backdrop-blur">
        <div class="mx-auto flex h-16 max-w-6xl items-center gap-4 px-4">
            <a href="{{ route('students.index') }}" class="flex items-center gap-2 font-bold text-slate-900">
                <span class="flex size-9 items-center justify-center rounded-lg bg-indigo-600 text-white">
                    <x-icon name="academic-cap" />
                </span>
                <span class="hidden sm:inline">{{ __('app.name') }}</span>
            </a>

            <nav class="ms-6 hidden items-center gap-1 md:flex" aria-label="{{ __('app.nav.menu') }}">
                @foreach ($nav as $item)
                    <a
                        href="{{ route($item['route']) }}"
                        @class([
                            'inline-flex min-h-11 items-center gap-2 rounded-lg px-3 text-sm font-semibold transition',
                            'bg-indigo-50 text-indigo-700' => request()->routeIs($item['match']),
                            'text-slate-600 hover:bg-slate-100 hover:text-slate-900' => ! request()->routeIs($item['match']),
                        ])
                        @if (request()->routeIs($item['match'])) aria-current="page" @endif
                    >
                        <x-icon :name="$item['icon']" />
                        {{ $item['label'] }}
                    </a>
                @endforeach
            </nav>

            <div class="ms-auto flex items-center gap-1">
                <a
                    href="{{ route('notifications.index') }}"
                    class="relative inline-flex size-11 items-center justify-center rounded-lg text-slate-600 hover:bg-slate-100 hover:text-slate-900"
                    aria-label="{{ __('app.nav.bell', ['count' => $attentionCount ?? 0]) }}"
                >
                    <x-icon name="bell" class="size-6" />
                    @if (($attentionCount ?? 0) > 0)
                        <span class="absolute top-1.5 end-1.5 flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1 text-[11px] font-bold leading-5 text-white ltr-nums">
                            {{ $attentionCount > 99 ? '99+' : $attentionCount }}
                        </span>
                    @endif
                </a>

                <div x-data="{ open: false }" class="relative" @click.outside="open = false" @keydown.escape="open = false">
                    <button type="button" @click="open = !open" :aria-expanded="open.toString()" class="inline-flex min-h-11 items-center gap-2 rounded-lg px-3 text-sm font-semibold text-slate-700 hover:bg-slate-100">
                        <span class="flex size-8 items-center justify-center rounded-full bg-slate-200 text-slate-700">{{ mb_substr(auth()->user()->name, 0, 1) }}</span>
                        <span class="hidden max-w-32 truncate sm:inline">{{ auth()->user()->name }}</span>
                    </button>
                    <div x-show="open" x-transition x-cloak class="card absolute end-0 mt-2 w-56 p-2 shadow-lg">
                        <p class="truncate px-3 py-2 text-xs text-slate-500">{{ auth()->user()->email }}</p>
                        <x-form :action="route('logout')">
                            <x-button variant="ghost" icon="logout" class="w-full !justify-start" :loading-text="__('app.nav.logout')">{{ __('app.nav.logout') }}</x-button>
                        </x-form>
                    </div>
                </div>
            </div>
        </div>
    </header>

    <x-toast />

    <main id="main" class="mx-auto max-w-6xl px-4 pt-6 pb-28 md:pb-12">
        {{ $slot }}
    </main>

    {{-- Mobile bottom navigation --}}
    <nav class="fixed inset-x-0 bottom-0 z-40 border-t border-slate-200 bg-white pb-[env(safe-area-inset-bottom)] md:hidden" aria-label="{{ __('app.nav.menu') }}">
        <div class="grid grid-cols-3">
            @foreach ($nav as $item)
                <a
                    href="{{ route($item['route']) }}"
                    @class([
                        'relative flex min-h-14 flex-col items-center justify-center gap-0.5 text-xs font-semibold',
                        'text-indigo-700' => request()->routeIs($item['match']),
                        'text-slate-500' => ! request()->routeIs($item['match']),
                    ])
                    @if (request()->routeIs($item['match'])) aria-current="page" @endif
                >
                    <x-icon :name="$item['icon']" class="size-6" />
                    {{ $item['label'] }}
                    @if ($item['route'] === 'notifications.index' && ($attentionCount ?? 0) > 0)
                        <span class="absolute top-1.5 start-1/2 ms-2 min-w-5 rounded-full bg-red-600 px-1 text-center text-[11px] leading-5 text-white ltr-nums">{{ $attentionCount }}</span>
                    @endif
                </a>
            @endforeach
        </div>
    </nav>

    {{ $modals ?? '' }}
</body>
</html>
