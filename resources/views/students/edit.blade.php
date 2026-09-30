<x-layouts.app :title="__('students.edit')">
    <div class="mx-auto max-w-2xl">
        <a href="{{ route('students.show', $student) }}" class="mb-4 inline-flex min-h-11 items-center gap-1 text-sm font-semibold text-slate-600 hover:text-slate-900">
            <x-icon name="chevron-right" class="size-4" /> {{ __('app.actions.back') }}
        </a>

        <div class="card p-6">
            <h1 class="mb-6 text-xl font-bold text-slate-900">{{ __('students.edit') }}</h1>

            <x-form :action="route('students.update', $student)" method="PUT" class="space-y-6">
                @include('students.partials.form-fields', ['student' => $student])

                <div class="flex flex-col-reverse gap-2 border-t border-slate-100 pt-6 sm:flex-row sm:justify-end">
                    <x-button :href="route('students.show', $student)" variant="secondary">{{ __('app.actions.cancel') }}</x-button>
                    <x-button>{{ __('app.actions.save') }}</x-button>
                </div>
            </x-form>
        </div>
    </div>
</x-layouts.app>
