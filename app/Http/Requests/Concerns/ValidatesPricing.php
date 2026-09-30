<?php

namespace App\Http\Requests\Concerns;

/**
 * Price + commission (profit) fields shared by the add-student and renewal forms.
 * Omitted fields fall back to the configured defaults; submitted-but-empty fields are errors.
 */
trait ValidatesPricing
{
    protected function mergeDefaultPricing(): void
    {
        $defaults = [
            'price' => config('subscriptions.pricing.price'),
            'commission' => config('subscriptions.pricing.commission'),
        ];

        foreach ($defaults as $field => $default) {
            if (! $this->exists($field)) {
                $this->merge([$field => $default]);
            }
        }
    }

    /**
     * @return array<string, list<string>>
     */
    protected function pricingRules(): array
    {
        return [
            'price' => ['required', 'numeric', 'decimal:0,2', 'min:0', 'max:99999999.99'],
            'commission' => ['required', 'numeric', 'decimal:0,2', 'min:0', 'lte:price'],
        ];
    }
}
