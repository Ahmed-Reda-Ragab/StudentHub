@php use App\Enums\Section; use App\Enums\SubscriptionStatus; @endphp

<x-layouts.app :title="__('dashboard.title')">
    <div class="mb-6 flex items-center justify-between gap-4">
        <h1 class="text-2xl font-bold text-slate-900">{{ __('dashboard.title') }}</h1>
        <x-button :href="route('notifications.index')" variant="secondary" icon="bell">{{ __('dashboard.go_notifications') }}</x-button>
    </div>

    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <x-stat-card :label="__('dashboard.total')" :value="$counts['all']" icon="users" :href="route('students.index')" />
        <x-stat-card :label="__('dashboard.active')" :value="$counts[SubscriptionStatus::Active->value]" icon="check-circle" tone="emerald"
            :href="route('students.index', ['status' => SubscriptionStatus::Active->value])" />
        <x-stat-card :label="__('dashboard.due_soon')" :value="$counts[SubscriptionStatus::DueTomorrow->value] + $counts[SubscriptionStatus::DueToday->value]" icon="clock" tone="amber"
            :href="route('notifications.index')" />
        <x-stat-card :label="__('dashboard.expired')" :value="$counts[SubscriptionStatus::Expired->value]" icon="x-circle" tone="red"
            :href="route('students.index', ['status' => SubscriptionStatus::Expired->value])" />
    </div>

    {{-- Students per section --}}
    <section class="card mt-6" aria-labelledby="sections-title">
        <h2 id="sections-title" class="border-b border-slate-100 px-5 py-4 text-base font-bold text-slate-900">{{ __('dashboard.sections.title') }}</h2>

        <div class="grid grid-cols-1 divide-y divide-slate-100 md:grid-cols-3 md:divide-x md:divide-y-0">
            @foreach (Section::grouped() as $group => $sections)
                <div class="min-w-0 p-5">
                    <div class="mb-3 flex items-center justify-between gap-2">
                        <h3 class="text-sm font-bold text-slate-500">{{ __('students.section_groups.'.$group) }}</h3>
                        <span class="rounded-full bg-slate-100 px-2 text-xs font-semibold leading-5 text-slate-600 ltr-nums">
                            {{ collect($sections)->sum(fn ($s) => $sectionCounts[$s->value]) }}
                        </span>
                    </div>
                    <ul class="space-y-3">
                        @foreach ($sections as $section)
                            @php $n = $sectionCounts[$section->value]; @endphp
                            <li>
                                <div class="flex items-center justify-between gap-2 text-sm">
                                    <span class="font-semibold text-slate-800">{{ $section->label() }}</span>
                                    <span class="font-bold text-slate-900 ltr-nums">{{ $n }}</span>
                                </div>
                                <div class="mt-1 h-1.5 overflow-hidden rounded-full bg-slate-100" aria-hidden="true">
                                    <div class="h-full rounded-full bg-indigo-500" style="width: {{ $counts['all'] ? round($n / $counts['all'] * 100, 1) : 0 }}%"></div>
                                </div>
                            </li>
                        @endforeach
                    </ul>
                </div>
            @endforeach
        </div>

        @if ($sectionCounts[''] > 0)
            <p class="border-t border-slate-100 px-5 py-3 text-sm text-slate-500">
                {{ __('dashboard.sections.missing', ['count' => $sectionCounts['']]) }}
            </p>
        @endif
    </section>
</x-layouts.app>
