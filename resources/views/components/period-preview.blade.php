{{-- Live preview for a start date held in the enclosing Alpine scope as `date`. --}}
<div class="mt-2 space-y-0.5 text-sm" x-show="$nextRenewal(date)" aria-live="polite">
    <p class="flex items-center gap-1.5 text-slate-600">
        <x-icon name="clock" class="size-4" />
        {{ __('students.preview_ends') }}
        <strong class="ltr-nums" x-text="$periodEnd(date)"></strong>
    </p>
    <p class="flex items-center gap-1.5 text-indigo-700">
        <x-icon name="calendar" class="size-4" />
        {{ __('students.preview') }}
        <strong class="ltr-nums" x-text="$nextRenewal(date)"></strong>
    </p>
</div>
