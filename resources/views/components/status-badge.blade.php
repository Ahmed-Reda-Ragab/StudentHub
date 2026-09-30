@props(['status'])

{{-- Color + icon + text, never color alone (color-blind friendly). --}}
<span {{ $attributes->merge(['class' => 'inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ring-inset '.$status->color()]) }}>
    <x-icon :name="$status->icon()" class="size-4" />
    {{ $status->label() }}
</span>
