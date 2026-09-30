{{-- Shared by create & edit. Subscription dates only appear on create. --}}
@php
    $student ??= null;
@endphp

<div class="grid gap-4 sm:grid-cols-2">
    <x-input name="name" :label="__('students.fields.name')" :value="$student?->name" required autofocus />
    <x-input name="phone" type="tel" :label="__('students.fields.phone')" :value="$student?->phone" inputmode="tel" dir="ltr" placeholder="01012345678" required />
    <x-input name="code" :label="__('students.fields.code')" :value="$student?->code" dir="ltr" required />
    @php $currentSection = (string) old('section', $student?->section?->value); @endphp
    <x-select name="section" :label="__('students.fields.section')" :placeholder="__('students.section_placeholder')" required>
        @foreach (\App\Enums\Section::grouped() as $group => $sections)
            <optgroup label="{{ __("students.section_groups.{$group}") }}">
                @foreach ($sections as $section)
                    <option value="{{ $section->value }}" @selected($currentSection === $section->value)>{{ $section->label() }}</option>
                @endforeach
            </optgroup>
        @endforeach
    </x-select>

    @unless ($student)
        <div x-data="{ date: @js(old('subscribed_on', today()->toDateString())) }">
            <x-input name="subscribed_on" type="date" :label="__('students.fields.subscribed_on')" x-model="date" required>
                <x-period-preview />
            </x-input>
        </div>

        <x-pricing-fields x-data="{
            price: {{ \Illuminate\Support\Js::from((string) old('price', config('subscriptions.pricing.price'))) }},
            commission: {{ \Illuminate\Support\Js::from((string) old('commission', config('subscriptions.pricing.commission'))) }},
        }" />
    @endunless

    <div class="sm:col-span-2">
        <x-textarea name="notes" :label="__('students.fields.notes')" :value="$student?->notes" />
    </div>
</div>
