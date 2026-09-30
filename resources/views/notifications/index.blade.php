@php
    use App\Enums\SubscriptionStatus;
    $total = $groups->sum(fn ($students) => $students->count());
@endphp

<x-layouts.app :title="__('notifications.title')">
    <div class="mb-6">
        <h1 class="text-2xl font-bold text-slate-900">{{ __('notifications.title') }}</h1>
        <p class="mt-1 text-sm text-slate-500">{{ __('notifications.subtitle') }}</p>
    </div>

    @if ($total === 0)
        <div class="card">
            <x-empty-state icon="check-circle" :title="__('notifications.empty')" />
        </div>
    @else
        <div class="space-y-6">
            @foreach ($groups as $statusValue => $students)
                @php $status = SubscriptionStatus::from($statusValue); @endphp
                <section class="card" aria-labelledby="group-{{ $statusValue }}">
                    <h2 id="group-{{ $statusValue }}" class="flex items-center gap-2 border-b border-slate-100 px-5 py-4 text-base font-bold text-slate-900">
                        <span aria-hidden="true">{{ $status->emoji() }}</span>
                        {{ $status->label() }}
                        <span class="rounded-full bg-slate-100 px-2 text-xs leading-5 text-slate-600 ltr-nums">{{ $students->count() }}</span>
                    </h2>

                    @if ($students->isEmpty())
                        <p class="px-5 py-4 text-sm text-slate-400">{{ __('notifications.group_empty') }}</p>
                    @else
                        <ul class="divide-y divide-slate-100">
                            @foreach ($students as $student)
                                <li class="flex flex-col gap-3 px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
                                    <div>
                                        <p class="font-semibold text-slate-900">
                                            {{ $student->name }}
                                            <span class="font-normal text-slate-500">— {{ __('students.fields.code') }} <span class="ltr-nums">{{ $student->code }}</span></span>
                                        </p>
                                        <p class="mt-0.5 text-sm text-slate-500">
                                            {{ __('students.fields.next_renewal_date') }}: <span class="ltr-nums">{{ $student->next_renewal_date->format('d/m/Y') }}</span>
                                        </p>
                                    </div>
                                    <div class="grid grid-cols-3 gap-2 sm:flex">
                                        <x-button :href="route('students.show', $student)" variant="secondary">{{ __('app.actions.open') }}</x-button>
                                        <x-whatsapp-button :student="$student" compact />
                                        <x-renew-button :student="$student" :label="__('subscriptions.renew.quick')" />
                                    </div>
                                </li>
                            @endforeach
                        </ul>
                    @endif
                </section>
            @endforeach
        </div>
    @endif

    @if ($history->isNotEmpty())
        <section class="mt-10" aria-labelledby="history-title">
            <h2 id="history-title" class="mb-3 text-sm font-bold text-slate-500">{{ __('notifications.history') }}</h2>
            <ul class="card divide-y divide-slate-100 text-sm">
                @foreach ($history as $notification)
                    <li class="flex items-center justify-between gap-4 px-5 py-3">
                        <span class="flex items-center gap-2 {{ $notification->read_at ? 'text-slate-600' : 'font-semibold text-slate-900' }}">
                            <x-icon name="bell" class="size-4 text-slate-400" />
                            {{ $notification->data['message'] ?? '' }}
                        </span>
                        <time class="shrink-0 text-xs text-slate-400 ltr-nums" datetime="{{ $notification->created_at->toIso8601String() }}">{{ $notification->created_at->format('d/m/Y') }}</time>
                    </li>
                @endforeach
            </ul>
        </section>
    @endif

    <x-slot:modals>
        <x-renewal-modal />
    </x-slot:modals>
</x-layouts.app>
