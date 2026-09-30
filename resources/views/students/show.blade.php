@php
    $status = $student->status();
    $days = $student->daysUntilRenewal();
@endphp

<x-layouts.app :title="$student->name">
    <a href="{{ route('students.index') }}" class="mb-4 inline-flex min-h-11 items-center gap-1 text-sm font-semibold text-slate-600 hover:text-slate-900">
        <x-icon name="chevron-right" class="size-4" /> {{ __('students.title') }}
    </a>

    <div class="grid gap-6 lg:grid-cols-3">
        {{-- Status card --}}
        <section class="card p-6 lg:order-last" aria-labelledby="status-title">
            <h2 id="status-title" class="sr-only">{{ __('students.fields.status') }}</h2>
            <x-status-badge :status="$status" class="!text-sm" />

            <p class="mt-4 text-3xl font-bold text-slate-900">
                @if ($days > 0)
                    {{ __('students.days_left', ['days' => trans_choice('app.days', $days, ['count' => $days])]) }}
                @elseif ($days === 0)
                    {{ __('students.due_today') }}
                @else
                    <span class="text-red-600">{{ __('students.days_overdue', ['days' => trans_choice('app.days', abs($days), ['count' => abs($days)])]) }}</span>
                @endif
            </p>

            <dl class="mt-6 space-y-3 text-sm">
                <div class="flex justify-between gap-4">
                    <dt class="text-slate-500">{{ __('students.fields.last_subscription_date') }}</dt>
                    <dd class="font-semibold ltr-nums">{{ $student->last_subscription_date->format('d/m/Y') }}</dd>
                </div>
                <div class="flex justify-between gap-4">
                    <dt class="text-slate-500">{{ __('students.fields.next_renewal_date') }}</dt>
                    <dd class="font-bold text-slate-900 ltr-nums">{{ $student->next_renewal_date->format('d/m/Y') }}</dd>
                </div>
            </dl>

            <div class="mt-6 grid gap-2">
                <x-renew-button :student="$student" class="w-full" />
                <x-whatsapp-button :student="$student" class="w-full" />
            </div>
        </section>

        {{-- Profile --}}
        <section class="card p-6 lg:col-span-2" aria-labelledby="profile-title">
            <div class="flex items-start justify-between gap-4">
                <div>
                    <p class="text-sm font-semibold text-slate-400 ltr-nums">#{{ $student->number }}</p>
                    <h1 id="profile-title" class="text-2xl font-bold text-slate-900">{{ $student->name }}</h1>
                </div>
                <div class="flex gap-1">
                    <x-button :href="route('students.edit', $student)" variant="secondary" icon="pencil-square">{{ __('app.actions.edit') }}</x-button>
                    <x-button type="button" variant="ghost" x-data x-on:click="$dispatch('open-modal', 'delete-student')" class="!px-3 text-red-600 hover:!bg-red-50 hover:!text-red-700" aria-label="{{ __('app.actions.delete') }}">
                        <x-icon name="trash" />
                    </x-button>
                </div>
            </div>

            <dl class="mt-6 grid gap-4 sm:grid-cols-3">
                <div>
                    <dt class="text-sm text-slate-500">{{ __('students.fields.code') }}</dt>
                    <dd class="mt-1 font-semibold ltr-nums">{{ $student->code }}</dd>
                </div>
                <div>
                    <dt class="text-sm text-slate-500">{{ __('students.fields.phone') }}</dt>
                    <dd class="mt-1 font-semibold"><a href="tel:{{ $student->phone }}" class="ltr-nums hover:text-indigo-600">{{ $student->phone }}</a></dd>
                </div>
                <div>
                    <dt class="text-sm text-slate-500">{{ __('students.fields.section') }}</dt>
                    <dd class="mt-1 font-semibold">{{ $student->section }}</dd>
                </div>
                @if ($student->notes)
                    <div class="sm:col-span-3">
                        <dt class="text-sm text-slate-500">{{ __('students.fields.notes') }}</dt>
                        <dd class="mt-1 whitespace-pre-line text-slate-700">{{ $student->notes }}</dd>
                    </div>
                @endif
            </dl>
        </section>

        {{-- Ledger (read-only) --}}
        <section class="card lg:col-span-2" aria-labelledby="history-title">
            <div class="border-b border-slate-100 p-6 pb-4">
                <h2 id="history-title" class="text-lg font-bold text-slate-900">{{ __('subscriptions.history.title') }}</h2>
                <p class="mt-1 text-xs text-slate-500">{{ __('subscriptions.history.read_only') }}</p>
            </div>
            <div class="overflow-x-auto">
            <table class="w-full text-sm">
                <thead class="text-xs font-semibold text-slate-500">
                    <tr>
                        <th scope="col" class="px-4 py-3 text-start sm:px-6">{{ __('subscriptions.history.type') }}</th>
                        <th scope="col" class="px-4 py-3 text-start sm:px-6">{{ __('subscriptions.history.start_date') }}</th>
                        <th scope="col" class="px-4 py-3 text-start sm:px-6">{{ __('subscriptions.history.ends_on') }}</th>
                        <th scope="col" class="px-4 py-3 text-start sm:px-6">{{ __('subscriptions.pricing.price') }}</th>
                        <th scope="col" class="px-4 py-3 text-start sm:px-6">{{ __('subscriptions.pricing.commission_short') }}</th>
                    </tr>
                </thead>
                <tbody class="divide-y divide-slate-100">
                    @foreach ($student->subscriptions as $subscription)
                        <tr @class(['bg-indigo-50/40' => $loop->first])>
                            <td class="px-4 py-3 sm:px-6">
                                <span @class([
                                    'inline-flex rounded-md px-2 py-0.5 text-xs font-semibold',
                                    'bg-indigo-50 text-indigo-700' => $subscription->type === \App\Enums\SubscriptionType::Initial,
                                    'bg-slate-100 text-slate-700' => $subscription->type === \App\Enums\SubscriptionType::Renewal,
                                ])>{{ $subscription->type->label() }}</span>
                            </td>
                            <td class="px-4 py-3 font-semibold ltr-nums sm:px-6">{{ $subscription->start_date->format('d/m/Y') }}</td>
                            <td class="px-4 py-3 text-slate-600 ltr-nums sm:px-6">{{ $subscription->ends_on->format('d/m/Y') }}</td>
                            <td class="px-4 py-3 sm:px-6"><x-money :value="$subscription->price" /></td>
                            <td class="px-4 py-3 text-emerald-700 sm:px-6"><x-money :value="$subscription->commission" /></td>
                        </tr>
                    @endforeach
                </tbody>
                <tfoot class="border-t border-slate-200 bg-slate-50 text-sm font-bold">
                    <tr>
                        <th scope="row" colspan="3" class="px-4 py-3 text-start sm:px-6">
                            {{ __('subscriptions.pricing.total_paid') }} / {{ __('subscriptions.pricing.total_commission') }}
                        </th>
                        <td class="px-4 py-3 sm:px-6"><x-money :value="$student->subscriptions->sum('price')" /></td>
                        <td class="px-4 py-3 text-emerald-700 sm:px-6"><x-money :value="$student->subscriptions->sum('commission')" /></td>
                    </tr>
                </tfoot>
            </table>
            </div>
        </section>
    </div>

    <x-slot:modals>
        <x-renewal-modal />

        <x-modal name="delete-student" :title="__('students.delete.title')">
            <p class="text-sm text-slate-600">{{ __('students.delete.body', ['name' => $student->name]) }}</p>
            <x-form :action="route('students.destroy', $student)" method="DELETE" class="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
                <x-button type="button" variant="secondary" x-on:click="$dispatch('close-modal', 'delete-student')">{{ __('app.actions.cancel') }}</x-button>
                <x-button variant="danger" icon="trash" :loading-text="__('app.actions.deleting')">{{ __('app.actions.delete') }}</x-button>
            </x-form>
        </x-modal>
    </x-slot:modals>
</x-layouts.app>
