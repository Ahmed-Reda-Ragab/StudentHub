@php use Carbon\CarbonImmutable; @endphp

<x-layouts.app :title="__('reports.title')">
    <div class="mb-6">
        <h1 class="text-2xl font-bold text-slate-900">{{ __('reports.title') }}</h1>
        <p class="mt-1 text-sm text-slate-500">{{ __('reports.subtitle') }}</p>
    </div>

    {{-- Date range filter --}}
    <div class="card mb-6 p-4 sm:p-5">
        <x-form :action="route('reports.index')" method="GET" class="grid gap-4 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
            <x-input name="from" type="date" :label="__('reports.filter.from')" :value="$from->toDateString()" required />
            <x-input name="to" type="date" :label="__('reports.filter.to')" :value="$to->toDateString()" required />
            <x-button icon="magnifying-glass" :loading-text="__('reports.filter.loading')">{{ __('reports.filter.submit') }}</x-button>
        </x-form>

        <div class="mt-4 flex flex-wrap gap-2">
            @foreach ($presets as $key => $range)
                @php $active = $range['from'] === $from->toDateString() && $range['to'] === $to->toDateString(); @endphp
                <a
                    href="{{ route('reports.index', $range) }}"
                    @class([
                        'inline-flex min-h-11 items-center rounded-full px-4 text-sm font-semibold ring-1 transition',
                        'bg-indigo-600 text-white ring-indigo-600' => $active,
                        'bg-white text-slate-700 ring-slate-200 hover:ring-slate-300' => ! $active,
                    ])
                    @if ($active) aria-current="true" @endif
                >{{ __('reports.presets.'.$key) }}</a>
            @endforeach
        </div>
    </div>

    <p class="mb-3 text-sm font-semibold text-slate-500">
        {{ __('reports.range', ['from' => $from->format('d/m/Y'), 'to' => $to->format('d/m/Y')]) }}
    </p>

    {{-- Totals --}}
    <div class="mb-6 grid gap-4 sm:grid-cols-3">
        <div class="card p-5">
            <p class="text-sm text-slate-500">{{ __('reports.totals.price') }}</p>
            <x-money :value="$totals['price_total']" class="mt-1 block text-2xl font-bold text-slate-900" />
        </div>
        <div class="card p-5">
            <p class="text-sm text-slate-500">{{ __('reports.totals.commission') }}</p>
            <x-money :value="$totals['commission_total']" class="mt-1 block text-2xl font-bold text-emerald-700" />
        </div>
        <div class="card p-5">
            <p class="text-sm text-slate-500">{{ __('reports.totals.count') }}</p>
            <p class="mt-1 text-2xl font-bold text-slate-900 ltr-nums">{{ $totals['count'] }}</p>
            <p class="mt-1 text-xs text-slate-500">{{ __('reports.totals.breakdown', ['initial' => $totals['initial_count'], 'renewal' => $totals['renewal_count']]) }}</p>
        </div>
    </div>

    @if ($totals['count'] === 0)
        <div class="card">
            <x-empty-state icon="chart-bar" :title="__('reports.empty')" />
        </div>
    @else
        <div class="grid gap-6 lg:grid-cols-5">
            {{-- Per day --}}
            <section class="card lg:col-span-2" aria-labelledby="daily-title">
                <h2 id="daily-title" class="border-b border-slate-100 px-5 py-4 text-base font-bold text-slate-900">{{ __('reports.daily.title') }}</h2>
                <div class="overflow-x-auto">
                    <table class="w-full text-sm">
                        <thead class="text-xs font-semibold text-slate-500">
                            <tr>
                                <th scope="col" class="px-4 py-3 text-start">{{ __('reports.daily.day') }}</th>
                                <th scope="col" class="px-4 py-3 text-start">{{ __('reports.daily.count') }}</th>
                                <th scope="col" class="px-4 py-3 text-start">{{ __('subscriptions.pricing.price') }}</th>
                                <th scope="col" class="px-4 py-3 text-start">{{ __('subscriptions.pricing.commission_short') }}</th>
                            </tr>
                        </thead>
                        <tbody class="divide-y divide-slate-100">
                            @foreach ($daily as $day)
                                <tr>
                                    <td class="px-4 py-3 font-semibold ltr-nums">{{ CarbonImmutable::parse($day->day)->format('d/m/Y') }}</td>
                                    <td class="px-4 py-3 ltr-nums">{{ $day->count }}</td>
                                    <td class="px-4 py-3"><x-money :value="$day->price_total" /></td>
                                    <td class="px-4 py-3 text-emerald-700"><x-money :value="$day->commission_total" /></td>
                                </tr>
                            @endforeach
                        </tbody>
                    </table>
                </div>
            </section>

            {{-- Entries --}}
            <section class="card lg:col-span-3" aria-labelledby="entries-title">
                <h2 id="entries-title" class="border-b border-slate-100 px-5 py-4 text-base font-bold text-slate-900">{{ __('reports.entries.title') }}</h2>
                <div class="overflow-x-auto">
                    <table class="w-full text-sm">
                        <thead class="text-xs font-semibold text-slate-500">
                            <tr>
                                <th scope="col" class="px-4 py-3 text-start">{{ __('subscriptions.history.start_date') }}</th>
                                <th scope="col" class="px-4 py-3 text-start">{{ __('reports.entries.student') }}</th>
                                <th scope="col" class="px-4 py-3 text-start">{{ __('subscriptions.history.type') }}</th>
                                <th scope="col" class="px-4 py-3 text-start">{{ __('subscriptions.pricing.price') }}</th>
                                <th scope="col" class="px-4 py-3 text-start">{{ __('subscriptions.pricing.commission_short') }}</th>
                            </tr>
                        </thead>
                        <tbody class="divide-y divide-slate-100">
                            @foreach ($entries as $entry)
                                <tr>
                                    <td class="px-4 py-3 ltr-nums">{{ $entry->start_date->format('d/m/Y') }}</td>
                                    <td class="px-4 py-3">
                                        <a href="{{ route('students.show', $entry->student_id) }}" class="font-semibold text-slate-900 hover:text-indigo-600">{{ $entry->student?->name }}</a>
                                        <span class="block text-xs text-slate-500">{{ __('students.fields.code') }} <span class="ltr-nums">{{ $entry->student?->code }}</span></span>
                                    </td>
                                    <td class="px-4 py-3">
                                        <span @class([
                                            'inline-flex rounded-md px-2 py-0.5 text-xs font-semibold',
                                            'bg-indigo-50 text-indigo-700' => $entry->type === \App\Enums\SubscriptionType::Initial,
                                            'bg-slate-100 text-slate-700' => $entry->type === \App\Enums\SubscriptionType::Renewal,
                                        ])>{{ $entry->type->label() }}</span>
                                    </td>
                                    <td class="px-4 py-3"><x-money :value="$entry->price" /></td>
                                    <td class="px-4 py-3 text-emerald-700"><x-money :value="$entry->commission" /></td>
                                </tr>
                            @endforeach
                        </tbody>
                    </table>
                </div>
                @if ($entries->hasPages())
                    <div class="border-t border-slate-100 p-4">{{ $entries->links() }}</div>
                @endif
            </section>
        </div>
    @endif
</x-layouts.app>
