<x-layouts.guest :title="__('auth.login.title')">
    <h1 class="text-xl font-bold text-slate-900">{{ __('auth.login.title') }}</h1>
    <p class="mt-1 text-sm text-slate-500">{{ __('auth.login.subtitle') }}</p>

    <x-form :action="route('login')" class="mt-6 space-y-4">
        <x-input name="email" type="email" :label="__('auth.fields.email')" autocomplete="username" dir="ltr" required autofocus />
        <x-input name="password" type="password" :label="__('auth.fields.password')" autocomplete="current-password" dir="ltr" required />

        <label class="flex min-h-11 items-center gap-2 text-sm text-slate-700">
            <input type="checkbox" name="remember" class="size-4 rounded border-slate-300 text-indigo-600 focus:ring-indigo-600">
            {{ __('auth.login.remember') }}
        </label>

        <x-button class="w-full" :loading-text="__('auth.login.loading')">{{ __('auth.login.submit') }}</x-button>
    </x-form>

    <p class="mt-6 text-center text-sm text-slate-600">
        {{ __('auth.login.no_account') }}
        <a href="{{ route('register') }}" class="font-semibold text-indigo-600 hover:text-indigo-500">{{ __('auth.register.title') }}</a>
    </p>
</x-layouts.guest>
