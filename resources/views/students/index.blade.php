<x-layouts.app :title="__('students.title')">
    <div class="mb-6 flex items-center justify-between gap-4">
        <h1 class="text-2xl font-bold text-slate-900">{{ __('students.title') }}</h1>
        <x-button :href="route('students.create')" icon="plus" class="hidden sm:inline-flex">{{ __('students.add') }}</x-button>
    </div>

    {{-- Search (debounced, swaps #students-results without a full reload) --}}
    <form
        method="GET"
        action="{{ route('students.index') }}"
        x-data="liveSearch(@js($term))"
        @submit.prevent="run($el)"
        role="search"
        class="mb-4"
    >
        @if ($status)
            <input type="hidden" name="status" value="{{ $status->value }}">
        @endif

        <label for="student-search" class="sr-only">{{ __('students.search.placeholder') }}</label>
        <div class="relative">
            <span class="pointer-events-none absolute inset-y-0 start-0 flex items-center ps-3 text-slate-400">
                <x-icon name="spinner" x-show="loading" x-cloak class="size-5 text-indigo-600" />
                <x-icon name="magnifying-glass" x-show="!loading" />
            </span>
            <input
                id="student-search"
                type="search"
                name="q"
                x-model="q"
                @input.debounce.300ms="run($el.form)"
                placeholder="{{ __('students.search.placeholder') }}"
                autocomplete="off"
                class="form-input !min-h-12 ps-10 pe-12 [&::-webkit-search-cancel-button]:hidden"
            >
            <button
                type="button"
                x-show="q.length"
                x-cloak
                @click="clear($el.form)"
                class="absolute inset-y-0 end-0 flex w-12 items-center justify-center text-slate-400 hover:text-slate-600"
                aria-label="{{ __('app.actions.clear') }}"
            >
                <x-icon name="x-mark" />
            </button>
        </div>
    </form>

    <div id="students-results">
        {{-- Status tabs with counters --}}
        @php
            $tabs = ['all' => __('students.filters.all')]
                + collect(\App\Enums\SubscriptionStatus::cases())->mapWithKeys(fn ($s) => [$s->value => $s->emoji().' '.__('subscriptions.tabs.'.$s->value)])->all();
            $current = $status?->value ?? 'all';
        @endphp
        <nav class="-mx-4 mb-4 flex gap-2 overflow-x-auto px-4 pb-1" aria-label="{{ __('students.fields.status') }}">
            @foreach ($tabs as $key => $label)
                <a
                    href="{{ route('students.index', array_filter(['q' => $term, 'status' => $key === 'all' ? null : $key])) }}"
                    @class([
                        'inline-flex min-h-11 shrink-0 items-center gap-2 rounded-full px-4 text-sm font-semibold ring-1 transition',
                        'bg-indigo-600 text-white ring-indigo-600' => $current === $key,
                        'bg-white text-slate-700 ring-slate-200 hover:ring-slate-300' => $current !== $key,
                    ])
                    @if ($current === $key) aria-current="page" @endif
                >
                    {{ $label }}
                    <span @class([
                        'rounded-full px-2 text-xs leading-5 ltr-nums',
                        'bg-white/20' => $current === $key,
                        'bg-slate-100 text-slate-600' => $current !== $key,
                    ])>{{ $counts[$key] }}</span>
                </a>
            @endforeach
        </nav>

        @if ($students->isEmpty())
            <div class="card">
                @if ($term !== '')
                    <x-empty-state icon="magnifying-glass" :title="__('students.search.no_results', ['term' => $term])" :body="__('students.search.no_results_hint')" />
                @elseif ($counts['all'] === 0)
                    <x-empty-state :title="__('students.empty.title')" :body="__('students.empty.body')">
                        <x-button :href="route('students.create')" icon="plus">{{ __('students.add_first') }}</x-button>
                    </x-empty-state>
                @else
                    <x-empty-state icon="check-circle" :title="__('students.empty.filtered')" />
                @endif
            </div>
        @else
            {{-- Desktop table --}}
            <div class="card hidden md:block">
                <table class="w-full text-sm">
                    <thead class="sticky top-16 z-10 bg-slate-50 text-xs font-semibold text-slate-500">
                        <tr>
                            <th scope="col" class="rounded-ss-xl px-4 py-3 text-start">{{ __('students.fields.number') }}</th>
                            <th scope="col" class="px-4 py-3 text-start">{{ __('students.fields.name') }}</th>
                            <th scope="col" class="px-4 py-3 text-start">{{ __('students.fields.code') }}</th>
                            <th scope="col" class="px-4 py-3 text-start">{{ __('students.fields.phone') }}</th>
                            <th scope="col" class="px-4 py-3 text-start">{{ __('students.fields.section') }}</th>
                            <th scope="col" class="px-4 py-3 text-start">{{ __('students.fields.last_subscription_date') }}</th>
                            <th scope="col" class="px-4 py-3 text-start">{{ __('students.fields.next_renewal_date') }}</th>
                            <th scope="col" class="rounded-se-xl px-4 py-3 text-start">{{ __('students.fields.status') }}</th>
                        </tr>
                    </thead>
                    <tbody class="divide-y divide-slate-100">
                        @foreach ($students as $student)
                            @php $rowStatus = $student->status(); @endphp
                            <tr
                                onclick="window.location='{{ route('students.show', $student) }}'"
                                @class([
                                    'cursor-pointer transition hover:bg-slate-50',
                                    'bg-red-50/60 hover:bg-red-50' => $rowStatus === \App\Enums\SubscriptionStatus::Expired,
                                ])
                            >
                                <td class="px-4 py-3 font-semibold text-slate-500 ltr-nums">{{ $student->number }}</td>
                                <td class="px-4 py-3 font-semibold text-slate-900">
                                    <a href="{{ route('students.show', $student) }}" class="hover:text-indigo-600">{{ $student->name }}</a>
                                </td>
                                <td class="px-4 py-3"><span class="ltr-nums">{{ $student->code }}</span></td>
                                <td class="px-4 py-3"><span class="ltr-nums">{{ $student->phone }}</span></td>
                                <td class="px-4 py-3 text-slate-600">{{ $student->section }}</td>
                                <td class="px-4 py-3"><span class="ltr-nums">{{ $student->last_subscription_date->format('d/m/Y') }}</span></td>
                                <td class="px-4 py-3 font-semibold"><span class="ltr-nums">{{ $student->next_renewal_date->format('d/m/Y') }}</span></td>
                                <td class="px-4 py-3"><x-status-badge :status="$rowStatus" /></td>
                            </tr>
                        @endforeach
                    </tbody>
                </table>
            </div>

            {{-- Mobile cards --}}
            <ul class="space-y-3 md:hidden">
                @foreach ($students as $student)
                    @php $rowStatus = $student->status(); @endphp
                    <li @class(['card p-4', '!bg-red-50/70' => $rowStatus === \App\Enums\SubscriptionStatus::Expired])>
                        <a href="{{ route('students.show', $student) }}" class="block">
                            <div class="flex items-start justify-between gap-3">
                                <div>
                                    <p class="font-bold text-slate-900">
                                        <span class="text-slate-400 ltr-nums">#{{ $student->number }}</span>
                                        {{ $student->name }}
                                    </p>
                                    <p class="mt-0.5 text-sm text-slate-500">
                                        {{ __('students.fields.code') }} <span class="ltr-nums">{{ $student->code }}</span> · {{ $student->section }}
                                    </p>
                                </div>
                                <x-status-badge :status="$rowStatus" />
                            </div>
                            <p class="mt-3 flex items-center gap-1.5 text-sm text-slate-600">
                                <x-icon name="calendar" class="size-4" />
                                {{ __('students.fields.next_renewal_date') }}:
                                <strong class="ltr-nums text-slate-900">{{ $student->next_renewal_date->format('d/m/Y') }}</strong>
                            </p>
                        </a>
                        @if ($rowStatus->needsAttention())
                            <div class="mt-3 grid grid-cols-2 gap-2">
                                <x-whatsapp-button :student="$student" compact />
                                <x-renew-button :student="$student" :label="__('subscriptions.renew.quick')" variant="secondary" />
                            </div>
                        @endif
                    </li>
                @endforeach
            </ul>

            <div class="mt-6">{{ $students->links() }}</div>
        @endif
    </div>

    {{-- Sticky add action on mobile (sits above the bottom nav) --}}
    <a
        href="{{ route('students.create') }}"
        class="fixed bottom-20 end-4 z-30 inline-flex size-14 items-center justify-center rounded-full bg-indigo-600 text-white shadow-lg hover:bg-indigo-500 sm:hidden"
        aria-label="{{ __('students.add') }}"
    >
        <x-icon name="plus" class="size-7" />
    </a>

    <x-slot:modals>
        <x-renewal-modal />
    </x-slot:modals>
</x-layouts.app>
