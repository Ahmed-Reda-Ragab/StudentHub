<x-layouts.guest :title="__('auth.register.title')">
    <h1 class="text-xl font-bold text-slate-900">{{ __('auth.register.title') }}</h1>
    <p class="mt-1 text-sm text-slate-500">{{ __('auth.register.subtitle') }}</p>

    <x-form :action="route('register')" class="mt-6 space-y-4">
        <x-input name="name" :label="__('auth.fields.name')" autocomplete="name" required autofocus />
        <x-input name="email" type="email" :label="__('auth.fields.email')" autocomplete="username" dir="ltr" required />
        <x-input name="password" type="password" :label="__('auth.fields.password')" autocomplete="new-password" dir="ltr" required />
        <x-input name="password_confirmation" type="password" :label="__('auth.fields.password_confirmation')" autocomplete="new-password" dir="ltr" required />

        <x-button class="w-full" :loading-text="__('auth.register.loading')">{{ __('auth.register.submit') }}</x-button>
    </x-form>

    <p class="mt-6 text-center text-sm text-slate-600">
        {{ __('auth.register.have_account') }}
        <a href="{{ route('login') }}" class="font-semibold text-indigo-600 hover:text-indigo-500">{{ __('auth.login.title') }}</a>
    </p>
</x-layouts.guest>
