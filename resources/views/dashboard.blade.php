@php use App\Enums\SubscriptionStatus; @endphp

<x-layouts.app :title="__('dashboard.title')">
    <div class="mb-6 flex items-center justify-between gap-4">
        <h1 class="text-2xl font-bold text-slate-900">{{ __('dashboard.title') }}</h1>
        <x-button :href="route('notifications.index')" variant="secondary" icon="bell">{{ __('dashboard.go_notifications') }}</x-button>
    </div>

    <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <x-stat-card :label="__('dashboard.total')" :value="$counts['all']" icon="users" :href="route('students.index')" />
        <x-stat-card :label="__('dashboard.active')" :value="$counts[SubscriptionStatus::Active->value]" icon="check-circle" tone="emerald"
            :href="route('students.index', ['status' => SubscriptionStatus::Active->value])" />
        <x-stat-card :label="__('dashboard.due_soon')" :value="$counts[SubscriptionStatus::DueTomorrow->value] + $counts[SubscriptionStatus::DueToday->value]" icon="clock" tone="amber"
            :href="route('notifications.index')" />
        <x-stat-card :label="__('dashboard.expired')" :value="$counts[SubscriptionStatus::Expired->value]" icon="x-circle" tone="red"
            :href="route('students.index', ['status' => SubscriptionStatus::Expired->value])" />
    </div>
</x-layouts.app>
